TrueNAS Certificate Deployer
===========================

Imports acme.sh ECC certificates from `/certs/<domain>_ecc/` and selects them
for the TrueNAS web interface. The entrypoint runs reconciliation at startup
and whenever `/certs/.deploy-signal` changes.

Certificate Rotation
--------------------

The final name is `acme_<domain with dots replaced by underscores>`, for example
`acme_zagreus_ad_kritikos_io`. TrueNAS does not support replacing an imported
certificate's PEM or private key in place, so each renewal receives a new ID.

1. Query TrueNAS and reuse a managed record containing the current full chain,
   preferring the record already selected for the UI.
2. If no matching record exists, import one with a temporary name ending in
   `_pending_<16-character full-chain hash>`.
3. Select its ID for the UI and request a UI restart when needed. Connect directly
   to HTTPS and require an exact match against the expected leaf certificate.
4. Confirm the selected UI certificate ID, then delete superseded managed records
   using non-forced deletion jobs. TrueNAS checks service dependencies and refuses
   deletion of certificates still referenced by services.
5. Rename the retained record to the stable name, request another UI restart to
   refresh certificate paths, and check the served certificate again.
6. Write the full-chain fingerprint to `/state/<domain>.fp` only after completion.

Managed names are the exact stable name, that name plus a numeric timestamp from
the previous deployer, or that name plus the temporary hash suffix. Only existing
certificate records not managed by TrueNAS's native ACME implementation qualify.
These names are reserved for this deployer. The default TrueNAS certificate,
other domains, CSRs, and differently named records are not deleted.

A failure leaves reconciliation incomplete and produces a nonzero deployer exit
status. The next startup or signal retries from TrueNAS's actual records, even
when the fingerprint is unchanged. It does not import another copy merely
because the previous switch, deletion, or rename failed. There is no periodic
retry loop beyond startup and certificate signals.

If another service still references an older certificate, move that service to
the new certificate separately. This deployer manages only the UI reference;
it does not alter other services or force deletion. The temporary name and old
records can remain until the dependency is removed and reconciliation reruns.
Failed activation retains old records but does not automatically roll back the
UI selection.

Configuration
-------------

- `TRUENAS_URI`: direct middleware WebSocket URL, default `ws://localhost/api/current`.
- `TRUENAS_API_KEY`: required credential supplied outside the image and repository.
- `TRUENAS_DEPLOY_DOMAINS`: comma-separated domains matching the ECC directory names.
- `TRUENAS_UI_RESTART`: defaults to `true`; required to finalize a new or legacy
  certificate's stable name. With `false`, the deployer never requests a restart
  and defers naming cleanup. Activation verification still applies.
- `TRUENAS_JOB_TIMEOUT`: job and TLS-verification timeout in seconds, default `300`.

TLS verification connects to the hostname in `TRUENAS_URI` and the configured
TrueNAS `ui_httpsport`, using the certificate domain as SNI. That hostname must
reach the TrueNAS UI directly, not a reverse proxy serving a different certificate.
The exact leaf certificate is pinned to the local ACME output; the probe does not
depend on the container's CA trust store. A connection failure or certificate
mismatch prevents cleanup.

TrueNAS has one UI certificate setting. Domains are processed in order, and the
last successfully selected domain owns that setting. Normally configure just the
UI certificate domain, including any additional names as SANs on that certificate.

The API key needs certificate read/write, system-general read/write, and access
to the jobs used by certificate create, delete, and update. The implementation
targets TrueNAS 27. Its `system.general.config` and `system.general.update`
responses expose `ui_certificate` as an integer ID or null, not an embedded
certificate object. Both selection checks use that ID directly, as defined by
the [TrueNAS 27 schema](https://github.com/truenas/middleware/blob/master/src/middlewared/middlewared/api/v27_0_0/system_general.py).
Renaming preserves the new ID, not the old certificate's ID.
