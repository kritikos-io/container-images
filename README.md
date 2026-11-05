# images

Container images published to `containers.kritikos.io`, built with Docker Compose.

```powershell
docker compose build          # all images
docker compose build postgres # one image
```

Database versions are build args supplied from [database/.env](database/.env); see
[database/compose.yaml](database/compose.yaml) for the wiring. RustFS build inputs
are pinned separately in [rustfs/.env](rustfs/.env).

RustFS policy, console and CORS fixes
------------------------------------

[rustfs/compose.yaml](rustfs/compose.yaml) builds
`containers.kritikos.io/system/rustfs:1.0.4-jwtfix.6` for `linux/amd64`.
This keeps the 1.0.4 source base and policy-variable backport from `1.0.4-jwtfix.1`,
updates the bundled console to v0.1.38, and retains scoped bucket-creation and OIDC
resource-variable support in console capability checks. The upstream console now
supplies the refresh-loop fix, replacing the former local patch. Building or
pushing this image does not modify the running RustFS container.

The [Containerfile](rustfs/Containerfile) compiles source rather than repackaging
an unmodified release binary. The upstream default Dockerfile downloads a release
binary and therefore would not incorporate a source patch.

| Input | Pin |
| --- | --- |
| RustFS source | 1.0.4 at `46337942d55f3a8e6a97b147ca98d9ea8115555d` |
| Backported fix | [4e48c390](https://github.com/rustfs/rustfs/commit/4e48c390e792859a250da60d7de9909df2d188f4) |
| Virtual-hosted CORS backport | Unmodified [d229c79e](https://github.com/rustfs/rustfs/commit/d229c79e38d128a29accad5deebfb13cdec11475), SHA-256 `ccfa31ad7f84ae2dad3695c03e2b30998e1d415721fbe3a6459de75b93364bad` |
| Rust toolchain | 1.99.1, with a digest-pinned Debian builder |
| Runtime | Official 1.0.4 amd64 image, pinned by digest |
| Embedded console | v0.1.38 at `c358a8239c5a42585f678f0f65d8f2608f65f850`, with the scoped-permission fix |
| Console toolchain | Node 22.23.4 in a digest-pinned Debian builder, pnpm 12.3.4 and the upstream frozen lock file |
| Code generators | protoc 35.1 and flatc 25.12.19, with SHA-256 checks |

The [patch](rustfs/policy-variables.patch) retains the upstream variable-name and
string-substitution fixes and their regression coverage, adapts the test insertion
points to 1.0.4, and adds bucket/object namespace cases. It tests own-prefix access,
other-user and lookalike-prefix denial, and absent/empty usernames. No native
Keycloak roles, AD memberships, RustFS policies or credentials are provisioned here.

The [virtual-hosted CORS patch](rustfs/virtual-hosted-cors.patch) is the unchanged
upstream commit patch. It resolves virtual-hosted bucket names using
`RUSTFS_SERVER_DOMAINS` before selecting bucket CORS for preflights and response
handling. The original 1.0.4 middleware treated a bucket-host request to `/` as
global and looked for buckets only in URL paths. Allowed origins remain solely
in each bucket's CORS rules: no Traefik origin list, path-style client switch or
custom LiveSync HTTP handler is required by this fix.

The build context includes the patch, Git preserves its LF line endings, and the
builder verifies its checksum before applying it after the policy-variable patch.
The upstream commit and checksum are recorded in the image labels. The patch
applies to the pinned source without editing its contents.

Console v0.1.38 includes the upstream
[permission-refresh fix](https://github.com/rustfs/console/commit/1483f7dd102251d9b23f3791dc9ab3d51cd9ac76).
The local refresh patch is removed. The build runs the upstream refresh regression
tests, including non-admin page stability, denied policy-status reads, permission
revocation, identity changes and initial loading. No IAM permissions are broadened.

The [scoped-permission patch](rustfs/console-scoped-permissions.patch) separates
opening the create dialog from permission to create the entered bucket name.
An exact-name or prefix grant can expose the dialog without granting creation on
every bucket. The form checks the entered name and shows an access-denied error for
unauthorized names. Bucket and object controls resolve `${jwt:preferred_username}`
from the authenticated `accountinfo` response's `username`, including `NotResource`
exclusions. Missing, invalid and unsupported variables are not replaced with
wildcards. The original policy is not mutated or written back; the server remains
the authorization authority.

The console builder checks its source commit and scoped-patch checksum, runs the
upstream refresh, scoped-creation/form, identity-context, policy-parser, object-transfer and
optional bucket-policy-status tests, then builds the production static export.
It preserves the upstream default
`/rustfs/console` base path and embeds the resulting assets in the server binary.
A denied public/private-status probe for another user's bucket remains an expected,
optional read; it must not restart the permission-loading cycle.

The Rust builder requires the complete `rustfs-policy` library test suite and the
`rustfs` library's `server::` tests to pass before compiling the release server.
The latter cover the HTTP, CORS and shared virtual-host bucket-resolution code.
It retains the normal musl release target and default feature
set, checks that the binary needs no dynamic ELF interpreter, and runs its version
command in the final image. The official runtime's entrypoint, user, environment,
ports and other runtime settings are inherited unchanged. Only the server binary,
license files and build metadata are supplied by this recipe. Node and pnpm are not
added to the runtime image.

Source and binary inputs are pinned, and Cargo and pnpm use their existing lock files
without updates. Debian build-dependency packages still follow the builder's configured
package repositories; this is not a claim of bit-for-bit reproducible output.

From this repository root, using the existing local Docker/BuildKit setup:

```powershell
docker compose build rustfs && docker compose push rustfs
```

The push is attempted only after a successful build. Reuse the existing Zot login;
if authentication is not configured, run `docker login containers.kritikos.io`
interactively. Do not put credentials in build args, version files or source.

This is a substantial source build. `RUSTFS_BUILD_JOBS=2` limits Cargo concurrency;
adjust the local builder's memory/disk allocation or lower that setting if needed.
Cargo dependency, Cargo target and pnpm package caches are retained by BuildKit.
Do not bypass the tests to work around a build failure.

Record the digest reported by the successful push. A versioned tag is still mutable;
deployment should use the reviewed digest. Deployment, storage compatibility,
existing administrative access, console/SSO behavior, and real allowed/denied S3
requests require separate owner-run acceptance before replacing the running server.
Building this image does not activate the `s3-users` policy.

For `1.0.4-jwtfix.6`, only offline patch applicability and recipe consistency are
checked at preparation time. The image build, Rust tests and live CORS/LiveSync
acceptance have not been run. After an owner-run build and deployment, verify
allowed and denied origins for both bucket-host `/` and object paths, GET and PUT
preflights, and actual signed responses. Test public ingress explicitly when DNS
differs between LAN and external clients.

When replacing these backports with upstream releases, review the source, compiler,
runtime, console and code-generator pins together. Update the corresponding patch
checksum after any patch edit, keep all patches LF-encoded, and use a new custom
image tag. Remove each backport only after confirming that the selected upstream
source contains its complete fix.

## Alpine version vs. PostgreSQL major

`ALPINE_VERSION` and `PG_MAJOR` are not independent. The Alpine-based images
(`pgpool`, `ldap2pg`, `ldap2mariadb`) install PostgreSQL packages with
`apk add postgresql${PG_MAJOR}-dev` / `-client`, and an Alpine image's `apk`
repositories are fixed to that release's branch. Each branch packages only a
subset of PostgreSQL majors, and that subset changes every release:

| Alpine branch | `postgresql*-dev` available   |
| ------------- | ----------------------------- |
| edge          | 18, 17, 16                    |
| v3.24         | 18, 17 (main), 16 (community) |
| v3.23         | 18, 17 (main), 16 (community) |
| v3.22         | 17, 16 (main), 15 (community) |

_Measured with `apk policy` inside each branch's image on 2026-08-15._

So `PG_MAJOR=18` requires Alpine 3.23 or newer. The coupling breaks in both
directions:

- Raising `PG_MAJOR` before Alpine's stable branch packages that major fails the
  build — a September PostgreSQL release will not reach a stable Alpine until
  that branch ships.
- Leaving `PG_MAJOR` behind while Alpine advances fails eventually too: ageing
  majors are demoted from `main` to `community`, then dropped. 16 has already
  fallen to community on v3.23, and 15 is gone from v3.23 onwards.

**Bump `ALPINE_VERSION` and `PG_MAJOR` together**, and confirm the target branch
carries `postgresql${PG_MAJOR}-dev` before doing so.

Pinning matters because `alpine:latest` is a mutable tag that follows Alpine's
roughly six-monthly releases, so the same commit can build against a different
base OS and a different package set on a later day. Note that `--no-cache` on
`apk add` does not pin anything — it only avoids a stale index, and package
versions still float within the branch.

`pgpool` is the image most exposed to this, since it is the one that *compiles*
against `postgresql${PG_MAJOR}-dev` rather than just installing a client. All
three Alpine-based images (`pgpool`, `ldap2pg`, `ldap2mariadb`) take
`ALPINE_VERSION` from `database/.env`, currently pinned to `3.23`.

## pgpool health check

pgpool ships no health endpoint of its own. Its `health_check_period` settings
govern how pgpool probes *its backends* to drive failover, and the PCP tools
(`pcp_node_info` and friends) need a `pcp.conf` user plus a password file, which
is more than a container probe should carry. The image therefore probes with
`pg_isready` against the pgpool port.

What that reports, measured against two live backends:

| Backend state                     | Health |
| --------------------------------- | ------ |
| all nodes up                      | green  |
| standby down, degenerated         | green  |
| primary down, standby promoted    | green  |
| during failover (~one check cycle)| red    |
| no node attached, or no primary   | red    |

So green means **pgpool can serve**, not that the cluster is healthy. Losing a
standby is invisible to it, and because pgpool keeps a node `down` until
`pcp_attach_node` is run, the probe stays green after a backend recovers while
the pool is still running on one node. Track node-level state with
`SHOW POOL_NODES` instead.

Two consequences for compose files consuming this image:

- `depends_on: condition: service_healthy` is the intended use — it stops
  dependents from starting against a pool that has no primary.
- Do not restart pgpool on unhealthy. Bouncing it during a backend outage resets
  its node status and drops the pool without fixing anything.

In a real streaming-replication cluster the survivor of a primary loss is in
recovery, so `find_primary_node` reports nothing until `failover_command`
promotes it; connections fail with `failed to create a backend connection` and
the probe goes red for that whole window. The check is therefore gated on
failover automation working, not merely on a node being up.
