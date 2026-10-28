# Decisions

## Full NFS storage (no Longhorn)

The 45 application PVCs were migrated from Longhorn to the NFS-backed `nfs-apps` StorageClass. Longhorn was single-node in practice (all volumes on srv0; bigpc had no Longhorn disk) and added a distributed control plane, iSCSI, and per-volume engine overhead. The app-data export lives at `current_target/k3s_live_state/nfs-apps`; `nfs-apps` is the default StorageClass; sizes are advisory; PVCs are RWX; `no_root_squash` is required for CSI subdir creation and app chowns. The active backup is the restic repository under `state_backups/restic`; the old tar archives under `k3s_state_backups`/`compose_state_backups` were removed after a staged restore was verified.

**Accepted risk:** SQLite/WAL and Postgres are latency-sensitive on NFS. The benchmark gate measured ~3× SQLite p95 and ~2.6× Postgres latency under disk load; full NFS was chosen anyway. The Immich Postgres image requires `IGNORE_DATABASE_FSTYPE=true` to start on NFS (set in `immich.yaml`).

## Static node labels (no NFD)

NFD/node-facts were removed. `infra.local/hostpath-main` and `infra.local/external-exposed` are set statically by `k3s-server.sh`; `k3s-join.sh --hostpath-main` labels a joined node that owns the Main host paths. There is no 60-second detector. `validate.sh` warns when srv0 is missing either label.

## Scheduling pinning (claims and hardware, not labels)

Workloads are pinned by what they consume: app data on a host path uses a statically bound `hostpath` PV/PVC with `infra.local/hostpath-main`, and hardware is requested as a generic-device-plugin extended resource (`infra.local/intel-gpu`, `infra.local/amd`, `infra.local/conbee`). The remaining pod selectors are for non-storage node requirements (the hostNetwork VPN/DNS and the lockdown port-blocker on `external-exposed`, the bigpc archive agent on its hostname) and the DaemonSets. Guacamole is unpinned because the Windows firewall accepts RDP from the LAN.

## Public geoblock API (no self-hosted GeoIP)

The GeoIP service, image source, `geoipupdate` secret, and Traefik wait-for-geoip init container were removed. The geoblock plugin calls `https://get.geojs.io/v1/ip/country/{ip}` (`apiTimeoutMs=2000`, cache 1000). The tradeoff: a geojs.io outage blocks public traffic (the plugin fails closed). If that becomes unacceptable, restoring a self-hosted MaxMind service is the fallback.

## Header gate removed (`BOOTSTRAP_PRIVATE_APPS`)

The local WASM header-gate plugin and its `authelia-with-optional-header-gate` chain were removed. The six apps with their own authentication (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) no longer have an Authelia forward-auth filter. For first boot, set `BOOTSTRAP_PRIVATE_APPS: "true"` so those six routes keep only the `websecure` parentRef (LAN/VPN) until Authelia is Ready. `validate.sh` warns while the flag is true. Jellyfin's chart gets a 120s-startup-tolerant liveness probe (the chart schema has no `livenessProbe.enabled` flag).

## State Backups task (restic)

The backup system is the scheduled `State Backups` task in the D$CPLN Task Runner, driven by the private `dscpln-config` repo (`apps/state-backup/config.json` + `tools/backup/state-backup.sh`). It writes a single encrypted, deduplicated restic repository at `state_backups/restic`, capturing the `auto-backup=true` PVCs and the srv0/vps0 Compose state; the task is backup-only. The vps0 Compose state is pulled from the generic `dscpln-agent` archive service over the private tunnel; the old app SSH key was retired. The Task Runner backup instance runs as root because the NFS app data is owned by fixed Postgres/Redis UIDs. Restore is the manual `scripts/restic-restore.sh` path so a fresh cluster does not depend on Task Runner being deployed. A staged restore of `contacts-config-pvc` was verified on 2026-10-19; the old tar path (`pvc-backup`, `pvc.sh`, `compose_state_backups/`, `k3s_state_backups/`) was removed afterwards.

The restic repository was re-initialized on 2026-10-19 after the old key was lost during the migration; the previous repository is preserved as `state_backups/restic-lost-key-20261019-165529` until the new history is verified.

## Prometheus instead of Mimir

The metrics store is Prometheus (`prom/prometheus`, 180-day retention, remote-write receiver) instead of Mimir. Alloy still scrapes and remote-writes; Loki, Grafana, the dashboards, and the 18 alert rules are unchanged. Prometheus runs on the `nfs-apps` PVC, which it warns is an unsupported filesystem — the same NFS tradeoff the Mimir PVC had. Mimir's historical metrics were not migrated; the TSDB starts fresh. The Mimir Deployment/Service/PVC/NetworkPolicy were removed after Prometheus was verified.

## Authelia access-control ownership

Structural rules stay in code: ACME/app bypasses and the final admin catch-all. Deployment-specific rules — hosts, groups, users, one-factor/two-factor policy — live in `config/srv0/values.yaml` as `AUTHELIA_ACCESS_CONTROL_RULES` (rendered by `tpl` between the bypasses and catch-all) and in `config/vps0/authelia/access_control.yml` for vps0. The vps0 base config is committed; `scripts/render-vps0-authelia.sh` injects the config rules and writes the live `configuration.yml` before `docker compose up`. The split keeps the reusable chart free of personal group names while preserving first-match ordering.

## Shared multi-SAN edge certificates

The per-app Let's Encrypt Certificates were replaced by `edge-public-tls` (the 25 exact public hostnames) and `edge-private-tls` (`files`, `traefik`). The public cert is attached to both secure listeners; the private cert only to `websecure`, so the private names never reach the public-exposure listener. The names are exact (not a wildcard), but all public names share one key, so a key compromise has wildcard-like blast radius; per-host key isolation was traded for fewer Orders and secrets. Adding a public app means adding its SAN and re-issuing.

## Docs split

The 72KB `AGENTS.md` was split into this `docs/` tree; `AGENTS.md` keeps the target table, commands, rules, and links. The detailed design/tradeoff notes live here and in `docs/security.md`.

## Public GHCR packages for app images

All six app images (`PixelNtfy`, `ISBN-Lookup`, `apps.obtainium.imranr.dev`, `our-times`, `order-manager`, `Logtfy`) publish to public GHCR packages. `our-times` and `order-manager` keep their source repos private, but the images contain only code and dependencies; public packages avoid vps0 registry auth and let Renovate refresh digests without `read:packages`. The tradeoff is that the image layers expose the compiled/readable app code.

## Infra-built images on GHCR

The nfs-server image (`ghcr.io/imranr98/nfs-server`) stays in this repo: the workflow builds on `nfs-server-src` changes, verifies the candidate digest, then promotes `:latest`. The opencode image now lives in its own app repo, `ImranR98/opencode-sandbox` (`ghcr.io/imranr98/opencode-sandbox`), with the same test → candidate → verify → promote pipeline as the other apps. Both use the workflow `GITHUB_TOKEN` with `packages: write`; the packages are public, so srv0 pulls anonymously and Renovate needs no `read:packages`. The old Docker Hub repositories are deprecated but not deleted. Docker Hub credentials remain only in `config/VARS.env` for Renovate's upstream lookups; the GitHub Actions Docker Hub secrets were removed.

## NFS image uses latest branch packages

The NFS server image no longer pins an exact `nfs-utils` version. It installs the latest `nfs-utils` and runs `apk upgrade --no-cache` for its pinned Alpine branch, and the image workflow rebuilds only when a Renovate dependency/base bump changes the source (the weekly schedule was removed). The image is tagged `latest`; the Deployment pins the digest. This trades reproducibility for automatic package freshness; the image build and verification are the gate. Alpine base updates remain Renovate PRs, with minor/major reviewed as Tier C.

## Sale site subdomain audiences

`sale-site` is one container/database serving `home.sale`, `tech.sale`, and `sale` hosts. Item visibility is assigned in the app, not by deploying separate instances. The root host is the distinct `@`/main audience; the Traefik routers keep the old `home-sale`/`tech-sale` names so their ACME certificates survive the consolidation. All three hosts share the app's `hs_vid` analytics cookie on `.cloud.imranr.dev`, while the app's admin session cookie remains host-scoped.

## Runtime security with Falco

Falco (chart 9.2.1 / Falco 0.45.1, `targets/srv0/k3s-base/templates/falco.yaml`) runs as a modern-eBPF DaemonSet on srv0 and bigpc. It is the runtime counterpart to CrowdSec (L7) and opencanary (honeypot): syscall rules catch shells, credential access, crypto miners, and escape helpers that HTTP-layer tools cannot see. The sensor uses the least-privileged eBPF capability set plus pod-level `spc_t` (SELinux denies container_t `perf_event_open`/BPF), reads `/proc`, `/etc` and `/sys/kernel` read-only, and uses the K3s containerd socket; `collectors.kubernetes` is off, so there is no k8s-metacollector or cluster-wide RBAC. `falcoctl` `follow` is disabled: rules/plugin updates ride Renovate chart bumps instead of in-cluster auto-updates. There is no falcosidekick/Talon: JSON events go to Loki through Alloy, metrics drive Grafana alerts, and response is manual. Event-rate alerts are added only after a rule-count observation window because the default rules are noisy on this stack. The k8saudit plugin and vps0 coverage remain future work.

## Accepted duplication (do not consolidate)

A simplification review triaged the repeated structures below and deliberately kept them as-is — don't propose helpers, `range` loops, anchors, or shared fragments for them again. The edge TLS certificates are the two shared multi-SAN Certificates above; the rest stay as-is.

- **k3s-apps per-app blocks** — the NFS PVCs, the `ExtensionRef` entries across the HTTPRoutes, and the probe stanzas: each app file is the per-app security/ownership record (size, middleware chain, probe type), and a generator would hide the one-line differences that matter. The PVCs are `nfs-apps`/RWX, but the per-app blocks stay.
- **`host-volumes.yaml`'s 11 PV/PVC pairs** (only name/path/size/node-label differ) — mechanical but stable; the explicit list keeps each host path auditable in place.
- **`radarr.yaml`/`sonarr.yaml`** (byte-identical apart from the image digest) and `prowlarr.yaml`: stable, and explicit image literals keep Renovate's extraction obvious.
- **`targets/pc` vs `targets/bigpc` compose** (~75 duplicated lines): `include:`/`extends:` would change project-dir and `.env` resolution for marginal gain.
- **vps0 compose repetition** — `x-logging` anchors are file-scoped and can't be shared across files; the public-exposure/authelia and postgres healthcheck stanzas, the `sale-site` service block, and the vps0 vs pc/bigpc socket-proxy variants stay explicit.
- **Small in-template repetition** — the chown/init containers, the Home Assistant `integration-update` downloader, and Authelia's 6 OIDC client blocks: a helper would add a second convention for marginal savings.
- **Already-correct repetition** — HTTPRoute `parentRefs` (the public vs LAN/VPN listener choice is the security boundary), the ReferenceGrants, and Grafana's alert-rule pipelines are per-item configuration. The `alerting/templates.yaml` label blocks (`volume`/`node`/`pod`/`cronjob`) are live: query series labels flow into alert labels.

Accepted security tradeoffs live in `docs/security.md`.
