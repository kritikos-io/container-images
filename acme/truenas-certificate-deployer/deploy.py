#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import socket
import ssl
import sys
import time
from typing import Any, cast
from urllib.parse import urlsplit

import websocket  # type: ignore[import-untyped]


TRUENAS_URI = os.environ.get("TRUENAS_URI", "ws://localhost/api/current")
API_KEY = os.environ["TRUENAS_API_KEY"]
DOMAINS = [d.strip() for d in os.environ.get("TRUENAS_DEPLOY_DOMAINS", "").split(",") if d.strip()]
UI_RESTART = os.environ.get("TRUENAS_UI_RESTART", "true").lower() in ("1", "true", "yes")
JOB_TIMEOUT = int(os.environ.get("TRUENAS_JOB_TIMEOUT", "300"))

CERTS_ROOT = pathlib.Path("/certs")
STATE_DIR = pathlib.Path("/state")


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S%z')}] {msg}", flush=True)


class RPC:
    def __init__(self, uri: str) -> None:
        log(f"connecting {uri}")
        self.uri = uri
        self.ws = websocket.create_connection(uri, timeout=30)
        self._id = 0

    def reconnect(self) -> None:
        self.close()
        self.ws = websocket.create_connection(self.uri, timeout=30)
        if not self.call("auth.login_with_api_key", [API_KEY]):
            raise RuntimeError("authentication failed after UI restart")

    def call(self, method: str, params: list[Any] | None = None) -> Any:
        self._id += 1
        req_id = str(self._id)
        request: dict[str, Any] = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            request["params"] = params
        self.ws.send(json.dumps(request))
        while True:
            msg = json.loads(self.ws.recv())
            if str(msg.get("id")) != req_id:
                # Discard unrelated notifications/events
                continue
            if "error" in msg:
                err = msg["error"]
                data = err.get("data") or {}
                raise RuntimeError(
                    f"RPC {method} failed: "
                    f"{data.get('reason') or err.get('message')}"
                )
            return msg["result"]

    def wait_job(self, job_id: int, timeout: int = JOB_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            jobs = self.call("core.get_jobs", [[["id", "=", job_id]]])
            if jobs:
                state = jobs[0].get("state")
                if state == "SUCCESS":
                    return jobs[0].get("result")
                if state in ("FAILED", "ABORTED"):
                    raise RuntimeError(f"job {job_id} {state}: {jobs[0].get('error')}")
            time.sleep(2)
        raise TimeoutError(f"job {job_id} did not finish within {timeout}s")

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:
            pass


def cert_dir(domain: str) -> pathlib.Path:
    return CERTS_ROOT / f"{domain}_ecc"


def fingerprint(pem: str) -> str:
    return hashlib.sha256(pem.encode()).hexdigest()


def state_file(domain: str) -> pathlib.Path:
    return STATE_DIR / f"{domain}.fp"


def verify_ui_certificate(rpc: RPC, domain: str, fullchain: str, config: dict[str, Any],
                          restart: bool = False) -> None:
    leaf = fullchain.split("-----END CERTIFICATE-----", 1)[0] + "-----END CERTIFICATE-----\n"
    expected = ssl.PEM_cert_to_DER_cert(leaf)
    host = urlsplit(TRUENAS_URI).hostname
    if not host:
        raise ValueError("TRUENAS_URI must contain a hostname")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    def matches() -> bool:
        with socket.create_connection((host, config["ui_httpsport"]), timeout=5) as connection:
            with context.wrap_socket(connection, server_hostname=domain) as secure:
                return secure.getpeercert(binary_form=True) == expected

    if not restart:
        try:
            if matches():
                return
        except OSError:
            pass
    if UI_RESTART:
        log(f"[{domain}] restarting UI before certificate verification")
        rpc.call("system.general.ui_restart", [0])
    deadline = time.monotonic() + JOB_TIMEOUT
    while time.monotonic() < deadline:
        try:
            if matches():
                if UI_RESTART:
                    rpc.reconnect()
                return
        except OSError:
            pass
        time.sleep(2)
    raise TimeoutError(f"[{domain}] UI did not serve the expected certificate; old certificates retained")


def deploy_domain(rpc: RPC, domain: str) -> bool:
    d = cert_dir(domain)
    if not d.is_dir():
        log(f"[{domain}] cert directory missing, skipping")
        return False

    try:
        fullchain = (d / "fullchain.cer").read_text()
        key = (d / f"{domain}.key").read_text()
    except OSError as e:
        log(f"[{domain}] cannot read cert files: {e}")
        return False

    fp = fingerprint(fullchain)
    sf = state_file(domain)
    restart = not sf.exists() or sf.read_text().strip() != fp
    name = f"acme_{domain.replace('.', '_')}"
    pending_name = f"{name}_pending_{fp[:16]}"
    if len(pending_name) > 120:
        raise ValueError(f"[{domain}] certificate name exceeds the TrueNAS 120-character limit")
    owned_name = re.compile(rf"{re.escape(name)}(?:_[0-9]+|_pending_[0-9a-f]{{16}})?")
    certificates: list[dict[str, Any]] = rpc.call("certificate.query", [])
    managed = [
        certificate for certificate in certificates
        if owned_name.fullmatch(certificate["name"])
        and certificate.get("cert_type_existing")
        and not certificate.get("acme")
    ]
    config: dict[str, Any] = rpc.call("system.general.config", [])
    selected_id: int | None = config["ui_certificate"]
    matching = [
        certificate for certificate in managed
        if (certificate.get("certificate") or "").strip() == fullchain.strip()
    ]
    matching.sort(key=lambda certificate: (
        certificate["id"] != selected_id, certificate["name"] != name, certificate["id"]
    ))
    if matching:
        result = matching[0]
        log(f"[{domain}] reusing cert id={result['id']}")
    else:
        sf.unlink(missing_ok=True)
        log(f"[{domain}] importing certificate '{pending_name}'")
        job_id = rpc.call("certificate.create", [{
            "create_type": "CERTIFICATE_CREATE_IMPORTED",
            "name": pending_name,
            "certificate": fullchain,
            "privatekey": key,
        }])
        result = rpc.wait_job(int(job_id))
        if not isinstance(result, dict) or "id" not in result:
            raise RuntimeError("unexpected certificate.create result")
        result = cast(dict[str, Any], result)
        restart = True
    cert_id = result["id"]
    if selected_id != cert_id:
        sf.unlink(missing_ok=True)
        log(f"[{domain}] setting UI certificate id={cert_id}")
        rpc.call("system.general.update", [{"ui_certificate": cert_id}])
        restart = True

    verify_ui_certificate(rpc, domain, fullchain, config, restart=restart)
    config = rpc.call("system.general.config", [])
    if config["ui_certificate"] != cert_id:
        raise RuntimeError(f"[{domain}] UI certificate selection changed; cleanup skipped")
    if result["name"] != name and not UI_RESTART:
        raise RuntimeError(f"[{domain}] enable TRUENAS_UI_RESTART to finalize certificate naming; cleanup skipped")

    for certificate in managed:
        if certificate["id"] != cert_id:
            log(f"[{domain}] deleting superseded certificate '{certificate['name']}'")
            job_id = rpc.call("certificate.delete", [certificate["id"], False])
            if rpc.wait_job(int(job_id)) is not True:
                raise RuntimeError(f"[{domain}] certificate deletion did not complete")

    if result["name"] != name:
        sf.unlink(missing_ok=True)
        log(f"[{domain}] renaming certificate to '{name}'")
        job_id = rpc.call("certificate.update", [cert_id, {"name": name}])
        renamed = rpc.wait_job(int(job_id))
        if not isinstance(renamed, dict) or cast(dict[str, Any], renamed).get("name") != name:
            raise RuntimeError(f"[{domain}] certificate rename did not complete")
        verify_ui_certificate(rpc, domain, fullchain, config, restart=True)

    sf.write_text(fp)
    log(f"[{domain}] deploy complete")
    return True


def main() -> int:
    if not DOMAINS:
        log("TRUENAS_DEPLOY_DOMAINS is empty, nothing to do")
        return 0

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log(f"target domains: {DOMAINS}")

    rpc = RPC(TRUENAS_URI)
    exit_code = 0
    try:
        if not rpc.call("auth.login_with_api_key", [API_KEY]):
            log("authentication failed")
            return 2
        for domain in DOMAINS:
            try:
                deploy_domain(rpc, domain)
            except Exception as e:
                log(f"[{domain}] deploy error: {e}")
                exit_code = 1
    finally:
        rpc.close()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
