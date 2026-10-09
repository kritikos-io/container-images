import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE = "/usr/local/lib/security/pam_ldap_direct.so"
HELPER = "/usr/lib/mysql/plugin/auth_pam_tool_dir/auth_pam_tool"
CONF = "/etc/pam_ldap.conf"
CA = "/etc/ssl/certs/ca-certificates.crt"


class ImageRecipeTests(unittest.TestCase):
    def test_linux_entrypoint_line_endings_are_preserved(self):
        self.assertIn("docker-entrypoint.sh text eol=lf", (ROOT / ".gitattributes").read_text())
        self.assertNotIn(b"\r", (ROOT / "docker-entrypoint.sh").read_bytes())

    def test_source_is_pinned_and_checked_before_build(self):
        recipe = (ROOT / "Containerfile").read_text()
        self.assertIn("ARG MARIADB_VERSION=13.0.2", recipe)
        self.assertIn("656448f091cbeb9efb3ece08e6868e40b8e7b6f8", recipe)
        self.assertIn("1aa622e85621b9018025e3483956d854566a5bc0636a4e8d9d005093f02dd16b", recipe)
        self.assertLess(recipe.index("sha256sum -c -"), recipe.index("./configure"))
        self.assertIn("--with-ldap-conf-file=/etc/pam_ldap.conf", recipe)
        self.assertIn("PERL5LIB=/build/pam_ldap make", recipe)

    def test_runtime_does_not_install_the_virtual_ldap_package(self):
        recipe = (ROOT / "Containerfile").read_text()
        self.assertNotIn("libpam-ldap", recipe)
        self.assertNotIn("nslcd", recipe)
        self.assertNotIn("mariadb-plugin-auth-pam || true", recipe)
        self.assertIn("libldap2", recipe)
        self.assertIn("util-linux", recipe)
        self.assertIn("command -v setpriv", recipe)
        self.assertIn("ldd \"$module\"", recipe)
        self.assertIn("not found", recipe)
        self.assertIn("chmod 4750", recipe)
        self.assertIn("gosu mysql test -x", recipe)

    def test_pam_stack_selects_the_exact_direct_module(self):
        stack = (ROOT / "pam.d" / "mariadb").read_text().splitlines()
        self.assertEqual(
            [["auth", "required", MODULE], ["account", "required", MODULE]],
            [line.split() for line in stack],
        )

    def test_stock_database_lifecycle_is_preserved(self):
        recipe = (ROOT / "Containerfile").read_text()
        entrypoint = (ROOT / "docker-entrypoint.sh").read_text()
        self.assertIn('ENTRYPOINT ["ldap-entrypoint.sh"]', recipe)
        self.assertIn('CMD ["mariadbd"]', recipe)
        self.assertIn('exec docker-entrypoint.sh "$@"', entrypoint)
        self.assertIn("healthcheck.sh --connect --innodb_initialized", recipe)
        self.assertNotIn("nslcd", entrypoint)
        self.assertIn("LC_ALL=C setpriv --dump", entrypoint)
        self.assertNotIn("/proc/self/status", entrypoint)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Requires a local POSIX shell; no Docker or lab access.")
class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mariadb-pam-entrypoint-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.conf = self.root / "pam_ldap.conf"
        self.module = self.root / "pam_ldap_direct.so"
        self.helper = self.root / "auth_pam_tool"
        self.ca = self.root / "ca.pem"
        self.status = self.root / "status"
        self.module.write_text("fixture-module")
        self.helper.write_text("fixture-helper")
        self.helper.chmod(0o4750)
        self.ca.write_text("fixture-ca")
        self.status.write_text("NoNewPrivs:\t0\n")
        text = (ROOT / "docker-entrypoint.sh").read_text()
        for old, new in (
            (MODULE, self.module), (HELPER, self.helper), (CONF, self.conf),
            (CA, self.ca), ("/proc/self/status", self.status),
        ):
            text = text.replace(old, str(new))
        self.script = self.root / "entrypoint.sh"
        self.script.write_text(text)
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "LDAPURI": "ldaps://directory.example.test",
            "LDAP_BASE": "DC=example,DC=test",
            "LDAPBINDDN": "CN=reader,DC=example,DC=test",
            "LDAPPASSWORD": "fixture-password-not-for-logs",
            "LDAP_LOGIN_ATTR": "sAMAccountName",
            "LDAP_TLS_REQCERT": "demand",
            "CERTS_GID": "12002",
            "TEST_CALLS": str(self.log),
            "TEST_HAVE_GROUP": "1",
            "TEST_UID": "0",
            "TEST_NO_NEW_PRIVS": "0",
            "TEST_SETPRIV_RC": "0",
        }
        self.stub("id", 'printf "%s\\n" "$TEST_UID"\n')
        self.stub("getent", 'if [ "$TEST_HAVE_GROUP" = 1 ]; then printf "certgroup:x:%s:\\n" "$2"; else exit 2; fi\n')
        self.stub("groupadd", 'printf "groupadd %s\\n" "$*" >> "$TEST_CALLS"\n')
        self.stub("usermod", 'printf "usermod %s\\n" "$*" >> "$TEST_CALLS"\n')
        self.stub(
            "setpriv",
            '[ "$1" = --dump ] || exit 9\n'
            '[ "$TEST_SETPRIV_RC" = 0 ] || exit "$TEST_SETPRIV_RC"\n'
            'printf "uid: 999\\nno_new_privs: %s\\n" "$TEST_NO_NEW_PRIVS"\n',
        )
        self.stub("docker-entrypoint.sh", 'printf "delegate %s\\n" "$*" >> "$TEST_CALLS"\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    def run_entrypoint(self, expected=0):
        result = subprocess.run(
            ["bash", str(self.script), "mariadbd", "--server-id=2", "--read-only=ON"],
            env=self.env, text=True, capture_output=True, timeout=5,
        )
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        self.assertNotIn(self.env.get("LDAPPASSWORD", "unused-secret"), result.stdout + result.stderr)
        return result

    def test_ldaps_writes_only_the_direct_module_configuration(self):
        self.run_entrypoint()
        text = self.conf.read_text()
        self.assertIn("uri ldaps://directory.example.test\n", text)
        self.assertIn("ssl on\n", text)
        self.assertIn("tls_checkpeer yes\n", text)
        self.assertIn(f"tls_cacertfile {self.ca}\n", text)
        self.assertIn("pam_login_attribute sAMAccountName\n", text)
        self.assertIn("bindpw fixture-password-not-for-logs\n", text)
        self.assertNotIn("tls_reqcert", text)
        self.assertEqual(0o600, stat.S_IMODE(self.conf.stat().st_mode))
        self.assertIn("usermod -aG certgroup mysql", self.log.read_text())
        self.assertIn("delegate mariadbd --server-id=2 --read-only=ON", self.log.read_text())

    def test_ldap_uses_starttls_not_plain_bind(self):
        self.env["LDAPURI"] = "ldap://directory.example.test:389"
        self.run_entrypoint()
        self.assertIn("ssl start_tls\n", self.conf.read_text())
        self.assertIn("tls_checkpeer yes\n", self.conf.read_text())

    def test_multiple_same_transport_uris_are_supported(self):
        self.env["LDAPURI"] = "ldaps://one.example.test ldaps://two.example.test"
        self.run_entrypoint()
        self.assertIn("uri " + self.env["LDAPURI"], self.conf.read_text())

    def test_mixed_transports_are_rejected(self):
        self.env["LDAPURI"] = "ldaps://one.example.test ldap://two.example.test"
        result = self.run_entrypoint(1)
        self.assertIn("cannot mix", result.stderr)
        self.assertFalse(self.log.exists())

    def test_weak_tls_verification_is_rejected(self):
        for value in ("allow", "try", "never"):
            with self.subTest(value=value):
                self.env["LDAP_TLS_REQCERT"] = value
                self.run_entrypoint(1)
        self.assertFalse(self.log.exists())

    def test_hard_is_an_alias_for_verified_tls(self):
        self.env["LDAP_TLS_REQCERT"] = "hard"
        self.run_entrypoint()
        self.assertIn("tls_checkpeer yes", self.conf.read_text())

    def test_missing_secret_is_not_defaulted(self):
        del self.env["LDAPPASSWORD"]
        result = self.run_entrypoint(1)
        self.assertIn("LDAPPASSWORD is required", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_newline_injection_fails_without_logging_the_secret(self):
        self.env["LDAPPASSWORD"] = "fixture-password-not-for-logs\ntls_checkpeer no"
        result = self.run_entrypoint(1)
        self.assertIn("must be a single line", result.stderr)
        self.assertNotIn("fixture-password-not-for-logs", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_missing_or_non_setuid_helper_is_reported_before_start(self):
        self.helper.chmod(0o0750)
        result = self.run_entrypoint(1)
        self.assertIn("setuid PAM helper", result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_module_is_reported_before_start(self):
        self.module.unlink()
        result = self.run_entrypoint(1)
        self.assertIn("direct LDAP PAM module is missing", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_missing_trust_store_fails_closed(self):
        self.ca.unlink()
        result = self.run_entrypoint(1)
        self.assertIn("system CA bundle", result.stderr)
        self.assertFalse(self.log.exists())

    def test_no_new_privileges_is_reported_before_start(self):
        self.status.write_text("NoNewPrivs:\t1\n")
        self.env["TEST_NO_NEW_PRIVS"] = "1"
        result = self.run_entrypoint(1)
        self.assertIn("no-new-privileges", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_missing_proc_status_field_does_not_block_startup(self):
        self.status.write_text("Name:\tmariadbd\nUid:\t999\t999\t999\t999\n")
        self.run_entrypoint()
        self.assertIn("delegate mariadbd", self.log.read_text())

    def test_failed_privilege_query_is_not_ignored(self):
        self.env["TEST_SETPRIV_RC"] = "1"
        result = self.run_entrypoint(1)
        self.assertIn("privilege constraints", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_malformed_privilege_query_is_not_ignored(self):
        self.env["TEST_NO_NEW_PRIVS"] = "unknown"
        result = self.run_entrypoint(1)
        self.assertIn("cannot determine", result.stderr)
        self.assertFalse(self.conf.exists())

    def test_certificate_group_is_created_when_missing(self):
        self.env["TEST_HAVE_GROUP"] = "0"
        self.run_entrypoint()
        self.assertIn("groupadd -g 12002 hostcerts", self.log.read_text())
        self.assertIn("usermod -aG hostcerts mysql", self.log.read_text())

    def test_invalid_login_attribute_and_gid_are_rejected(self):
        for key, value in (("LDAP_LOGIN_ATTR", "uid)(objectClass)=*"), ("CERTS_GID", "not-a-gid")):
            with self.subTest(key=key):
                previous = self.env[key]
                self.env[key] = value
                self.run_entrypoint(1)
                self.env[key] = previous
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
