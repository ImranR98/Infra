# Decisions

## Full NFS storage (no Longhorn)

The 45 application PVCs were migrated from Longhorn to the NFS-backed `nfs-apps` StorageClass. Longhorn was single-node in practice (all volumes on srv0; bigpc had no Longhorn disk) and added a distributed control plane, iSCSI, and per-volume engine overhead. The app-data export lives at `current_target/k3s_live_state/nfs-apps`; `nfs-apps` is the default StorageClass; sizes are advisory; PVCs are RWX; `no_root_squash` is required for CSI subdir creation and app chowns. The active backup is the restic repository under `state_backups/restic`; the old tar archives under `k3s_state_backups`/`compose_state_backups` were removed after a staged restore was verified.

**Accepted risk:** SQLite/WAL and Postgres are latency-sensitive on NFS. The benchmark gate measured ~3× SQLite p95 and ~2.6× Postgres latency under disk load; full NFS was chosen anyway. The Immich Postgres image requires `IGNORE_DATABASE_FSTYPE=true` to start on NFS (set in `immich.yaml`).

## Static node labels (no NFD)

NFD/node-facts were removed. `infra.local/hostpath-main` and `infra.local/external-exposed` are set statically by `k3s-server.sh`; `k3s-join.sh --hostpath-main` labels a joined node that owns the Main host paths. There is no 60-second detector. `validate.sh` warns when srv0 is missing either label.

## Public geoblock API (no self-hosted GeoIP)

The GeoIP service, image source, `geoipupdate` secret, and Traefik wait-for-geoip init container were removed. The geoblock plugin calls `https://get.geojs.io/v1/ip/country/{ip}` (`apiTimeoutMs=2000`, cache 1000). The tradeoff: a geojs.io outage blocks public traffic (the plugin fails closed). If that becomes unacceptable, restoring a self-hosted MaxMind service is the fallback.

## Header gate removed (`BOOTSTRAP_PRIVATE_APPS`)

The local WASM header-gate plugin and its `authelia-with-optional-header-gate` chain were removed. The six apps with their own authentication (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) no longer have an Authelia forward-auth filter. For first boot, set `BOOTSTRAP_PRIVATE_APPS: "true"` so those six routes keep only the `websecure` parentRef (LAN/VPN) until Authelia is Ready. `validate.sh` warns while the flag is true. Jellyfin's chart gets a 120s-startup-tolerant liveness probe (the chart schema has no `livenessProbe.enabled` flag).

## State Backups task (restic)

The backup system is the scheduled `State Backups` task in the D$CPLN Task Runner, driven by the private `dscpln-config` repo (`apps/state-backup/config.json` + `tools/backup/state-backup.sh`). It writes a single encrypted, deduplicated restic repository at `state_backups/restic`, capturing the `auto-backup=true` PVCs and the srv0/vps0 Compose state; the task is backup-only. The vps0 Compose state is pulled from the generic `dscpln-agent` archive service over the private tunnel; the old app SSH key was retired. The Task Runner backup instance runs as root because the NFS app data is owned by fixed Postgres/Redis UIDs. Restore is the manual `scripts/restic-restore.sh` path so a fresh cluster does not depend on Task Runner being deployed. A staged restore of `contacts-config-pvc` was verified on 2026-10-19; the old tar path (`pvc-backup`, `pvc.sh`, `compose_state_backups/`, `k3s_state_backups/`) was removed afterwards.

The restic repository was re-initialized on 2026-10-19 after the old key was lost during the migration; the previous repository is preserved as `state_backups/restic-lost-key-20261019-165529` until the new history is verified.

## Prometheus instead of Mimir

The metrics store is Prometheus (`prom/prometheus`, 180-day retention, remote-write receiver) instead of Mimir. Alloy still scrapes and remote-writes; Loki, Grafana, the dashboards, and the 18 alert rules are unchanged. Prometheus runs on the `nfs-apps` PVC, which it warns is an unsupported filesystem — the same NFS tradeoff the Mimir PVC had. Mimir's historical metrics were not migrated; the TSDB starts fresh. The Mimir Deployment/Service/PVC/NetworkPolicy were removed after Prometheus was verified.

## Shared multi-SAN edge certificates

The per-app Let's Encrypt Certificates were replaced by `edge-public-tls` (the 24 exact public hostnames) and `edge-private-tls` (`files`, `traefik`). The public cert is attached to both secure listeners; the private cert only to `websecure`, so the private names never reach the public-exposure listener. The names are exact (not a wildcard), but all public names share one key, so a key compromise has wildcard-like blast radius; per-host key isolation was traded for fewer Orders and secrets. Adding a public app means adding its SAN and re-issuing.

## Docs split

The 72KB `AGENTS.md` was split into this `docs/` tree; `AGENTS.md` keeps the target table, commands, rules, and links. The detailed design/tradeoff notes live here and in `docs/security.md`.

## Accepted duplication (do not consolidate)

A simplification review triaged the repeated structures below and deliberately kept them as-is — don't propose helpers, `range` loops, anchors, or shared fragments for them again. The edge TLS certificates are the two shared multi-SAN Certificates above; the rest stay as-is.

- **k3s-apps per-app blocks** — the NFS PVCs, the `ExtensionRef` entries across the HTTPRoutes, and the probe stanzas: each app file is the per-app security/ownership record (size, middleware chain, probe type), and a generator would hide the one-line differences that matter. The PVCs are `nfs-apps`/RWX, but the per-app blocks stay.
- **`host-volumes.yaml`'s 11 PV/PVC pairs** (only name/path/size/node-label differ) — mechanical but stable; the explicit list keeps each host path auditable in place.
- **`radarr.yaml`/`sonarr.yaml`** (byte-identical apart from the image digest) and `prowlarr.yaml`: stable, and explicit image literals keep Renovate's extraction obvious.
- **`targets/pc` vs `targets/bigpc` compose** (~75 duplicated lines): `include:`/`extends:` would change project-dir and `.env` resolution for marginal gain.
- **vps0 compose repetition** — `x-logging` anchors are file-scoped and can't be shared across files; the public-exposure/authelia and postgres healthcheck stanzas, the `tech-sale`/`home-sale` service blocks, and the vps0 vs pc/bigpc socket-proxy variants stay explicit.
- **Small in-template repetition** — the chown/init containers, the Home Assistant `integration-update` downloader, and Authelia's 6 OIDC client blocks: a helper would add a second convention for marginal savings.
- **Already-correct repetition** — HTTPRoute `parentRefs` (the public vs LAN/VPN listener choice is the security boundary), the ReferenceGrants, and Grafana's alert-rule pipelines are per-item configuration. The `alerting/templates.yaml` label blocks (`volume`/`node`/`pod`/`cronjob`) are live: query series labels flow into alert labels.

Accepted security tradeoffs live in `docs/security.md`.
