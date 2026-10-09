# MariaDB with direct LDAP PAM authentication

This image keeps MariaDB's `auth_pam` plugin and a direct LDAP PAM module. No nslcd or SSSD daemon
is configured or started. The existing SQL accounts `IDENTIFIED VIA pam USING 'mariadb'` and the
MaxScale clear-password pass-through configuration remain unchanged.

## Why the package name was insufficient

In Ubuntu 26.04, [libpam-ldap](https://packages.ubuntu.com/resolute/libpam-ldap) is a virtual package
provided by [libpam-ldapd](https://packages.ubuntu.com/resolute/libpam-ldapd). That implementation's
`pam_ldap.so` requires nslcd. An `apt-get install libpam-ldap` request therefore did not install
the direct module described by the old image comments.

The [Containerfile](Containerfile) now builds the direct PADL implementation from
[commit 656448f091cbeb9efb3ece08e6868e40b8e7b6f8](https://github.com/PADL/pam_ldap/tree/656448f091cbeb9efb3ece08e6868e40b8e7b6f8).
The downloaded archive must match SHA256
`1aa622e85621b9018025e3483956d854566a5bc0636a4e8d9d005093f02dd16b`.
The build and runtime stages share the same MariaDB base, avoiding cross-distribution library copies.
Only the built module and its license files are copied into the runtime stage.

The module is installed at `/usr/local/lib/security/pam_ldap_direct.so` and selected by that
absolute path in [pam.d/mariadb](pam.d/mariadb). A distro module with the same generic
`pam_ldap.so` name cannot silently replace it in this PAM stack.

This is legacy upstream code, not a claim that the distribution now supports it. Its revision,
dependencies and authentication behavior need review when updating the image. The build selects
the source's GNU C89 dialect and supplies its source directory in `PERL5LIB` for the upstream
version generator; neither change suppresses an authentication or TLS failure.

## Runtime configuration

The [entrypoint](docker-entrypoint.sh) continues to accept the existing variables:

| Variable | Meaning |
| --- | --- |
| `LDAPURI` | One or more whitespace-separated LDAP endpoints, all using the same transport |
| `LDAP_BASE` | User-search base DN |
| `LDAPBINDDN` | Existing directory search account's bind DN |
| `LDAPPASSWORD` | Its password, supplied at runtime, never in the image or repository |
| `LDAP_LOGIN_ATTR` | Login-name attribute, such as `sAMAccountName` |
| `LDAP_TLS_REQCERT` | `demand` or `hard`; weaker verification is rejected |
| `CERTS_GID` | The actual host TLS-key group ID, retained in mysql's groups after the stock privilege drop |

All values must be single-line, and required credentials have no defaults. The renderer writes
one root-only `/etc/pam_ldap.conf`, which is the path compiled into the direct module. It no longer
writes a second `/etc/ldap.conf`.

PADL's verification directive is `tls_checkpeer yes`, not `tls_reqcert`. Its CA-file directive
is `tls_cacertfile`; this image points it to `/etc/ssl/certs/ca-certificates.crt`, installed by
`ca-certificates`. No private CA file is required for the lab's Let's Encrypt certificates.
Endpoints must still provide a valid full chain for their hostnames.

`ldaps://` endpoints use LDAPS. `ldap://` endpoints explicitly use StartTLS before binding.
Mixing those transports in one endpoint list is rejected rather than silently selecting an
incompatible mode or permitting an unencrypted fallback.

The MariaDB PAM helper remains setuid root so it can read the bind credential. The build checks
the MariaDB plugin/helper and direct module dependencies, restricts the helper directory to
root and mysql, and verifies mysql can execute the helper. Do not enable `no-new-privileges`
for this backend container: it would prevent that elevation. Startup now reports this
configuration error explicitly instead of proceeding to generic access-denied failures.

The privilege check uses `setpriv --dump` from `util-linux`, which queries the kernel's
`PR_GET_NO_NEW_PRIVS` interface. It does not depend on a `NoNewPrivs` line in process status:
that field only appeared in Linux 4.10, whereas the kernel query exists since 3.5. This matters on
older Synology kernels. A confirmed flag value of 1 is still rejected; an unavailable or malformed
query fails explicitly rather than silently assuming privilege elevation will work.

The stock MariaDB entrypoint, certificate group handling, data directory, replication settings
and database healthcheck remain in use. This change does not create accounts, change passwords,
reseed databases, or alter database ownership.

## Build and rollout

The default engine version is explicitly `13.0.2`, matching the running primary and replica
observed during this incident. The old custom tag `11.8` actually contained MariaDB 13.0.2;
do not deploy an actual 11.8 binary against the restored 13.0 data.

From this image directory, the owner can build a distinctly named image:

```sh
docker build -f Containerfile -t containers.kritikos.io/system/mariadb-extended:13.0.2-pam-direct .
```

Publish and pin the resulting image digest through the normal registry workflow. The assistant
does not build, push or deploy images to the lab.

Deploy to zagreus first, retaining its data mount, server ID, read-only setting, replication
configuration, full-chain certificate and actual `CERTS_GID`. Check a direct AD-authenticated
MariaDB connection to zagreus before changing Plutus. Then update only Plutus's MariaDB container;
that briefly disconnects primary clients, but requires no NAS reboot and no PostgreSQL restart.

Verify on each updated backend:

```sh
docker exec mariadb mariadbd --version
docker exec mariadb cat /etc/pam.d/mariadb
docker exec mariadb ldd /usr/local/lib/security/pam_ldap_direct.so
```

The PAM service must name the explicit direct module, its dependencies must resolve, and the
engine must remain 13.0.2. Do not print `/etc/pam_ldap.conf`; it contains the directory bind password.

Then, from a client, use a real directory user's password with verified TLS:

```sh
mariadb --no-defaults --protocol=TCP --host=zagreus.ad.kritikos.io --port=3306 --user=kritikos --password --ssl --ssl-verify-server-cert --database=grimmory --execute='SELECT CURRENT_USER(), CURRENT_ROLE(), @@server_id;'
```

Repeat against plutus and finally `mariadb.kritikos.io` through MaxScale. A root or monitoring
account using native-password authentication does not validate PAM. Check replica status and
ordinary database health as well; this image does not change the existing replication channel.

## Validation scope

The pinned source was compiled and dynamically loaded locally under WSL with available PAM and
OpenLDAP headers. The compiled module exported `pam_sm_authenticate` and `pam_sm_acct_mgmt`,
linked directly to `libldap`, and detected both `ldap_initialize` and StartTLS support.
That was a local build, not execution inside the target Ubuntu image or against AD.

[tests/test_pam_image.py](tests/test_pam_image.py) checks the pinned image recipe and runs a
rendered entrypoint in temporary directories with stubbed identity/group/stock-entrypoint commands.
It exercises TLS modes, configuration generation, credential redaction, missing components,
privilege constraints and argument forwarding without contacting hosts:

```sh
python3 -m unittest discover -s tests -v
```

Entrypoint execution tests need a POSIX environment. The assistant has not built or deployed the
Docker image. On 2026-10-03, the owner verified the `kritikos` PAM/AD login directly against both
backends over verified TLS, with the expected aggregate role and primary/replica server IDs.

The later successful read through MaxScale required a separate site configuration correction on
zagreus: `bind_address = *`, providing both IPv4 and IPv6 listeners. Its IPv4-only listener did not
cover the IPv6 addresses advertised by its hostname. This was a backend listener change, not an
LDAP password, grant or TLS-verification change.

A later controlled test wrote one row through MaxScale to Plutus (server ID 1, read-only OFF)
and read the same row directly on zagreus (server ID 2, read-only ON), retaining the recorded
writer server ID 1. That verifies primary write routing and replication of a new row. It does not
establish failover behavior or crash durability. Cleanup of the disposable probe table was not
shown in those results.
