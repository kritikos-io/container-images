# images

Container images published to `containers.kritikos.io`, built with Docker Compose.

```powershell
docker compose build          # all images
docker compose build postgres # one image
```

Every version is a build arg supplied from [database/.env](database/.env); see
[database/compose.yaml](database/compose.yaml) for the wiring.

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
