# AGENTS.md

Infra is the infrastructure-as-code repo for a multi-machine homelab. Everything a target needs lives in `targets/<t>/`; shared logic sits in `scripts/`; secrets live in the gitignored `config/`. There is no build step in this repo. Target-selecting scripts (`validate`) take `<target>` as their first argument; machine-local scripts (`prereqs`, `renovate`, `preboot`, `wireguard`, `kubeconfig-unlock`, `k3s-server`, `k3s-join`, `restic-restore`) act on the machine they run on.

## Targets

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + public-exposure client Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, public-exposure WireGuard hub, web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm); syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

## Commands

Run `validate.sh` before every `helm upgrade --install`.

```bash
# Preflight — read-only, any machine:
bash scripts/validate.sh srv0
bash scripts/validate.sh vps0

# K3s (srv0) — the kubeconfig is root-only. Unlock it in another terminal:
bash scripts/kubeconfig-unlock.sh
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
helm uninstall srv0-apps -n apps     # delete apps first, then srv0-base

# Compose — from the repo root, ON the target machine:
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  up -d --remove-orphans
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  down <svc>                         # then up -d <svc> to restart one service
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  up -d --force-recreate --no-deps <svc>   # after editing an inline content: config
docker compose --env-file config/srv0/compose.env \
  -f targets/srv0/compose/compose.yaml up -d      # public-exposure client
# pc/bigpc/rpi: docker compose -f targets/<t>/compose/compose.yaml up -d
#   (no --env-file; the project-dir machine-fact .env auto-loads)

# Backups (State Backups app; manual restore):
bash scripts/restic-restore.sh list
bash scripts/restic-restore.sh pvc <pvc-name> [snapshot] [--live]
bash scripts/restic-restore.sh compose srv0|vps0 [snapshot] [--live]
sudo bash scripts/update-node-ip.sh [--ip X] [--force]

# Machine-local (no target):
bash scripts/prereqs.sh
bash scripts/renovate.sh [--dry-run]
bash scripts/preboot.sh public-exposure|crypt-ssh
bash scripts/wireguard.sh <path/to/wg0.conf>
bash scripts/k3s-server.sh
bash scripts/k3s-join.sh <node_ip> <node_user> \
  [--role agent|server] [--scheduling-discouraged] [--hostpath-main]

# Dev-only lint:
shellcheck $(find scripts targets -name '*.sh')
yamllint -c .yamllint targets/*/config_template \
  targets/srv0/k3s-base/values.yaml targets/srv0/k3s-base/Chart.yaml targets/srv0/k3s-base/files \
  targets/srv0/k3s-apps/values.yaml targets/srv0/k3s-apps/Chart.yaml
```

Scripts warn or hard-fail (`require_target_host`) on hostname/target mismatches. Pass `-y` to PVC commands for non-interactive confirmations.

## Documentation

- [Architecture](docs/architecture.md) — targets, layout, bootstrap order
- [Networking](docs/networking.md) — Traefik/Gateway, public exposure, VPN, DNS, static labels
- [Storage](docs/storage.md) — NFS, `nfs-apps`, backups/restore, performance note
- [Security](docs/security.md) — auth, NetworkPolicies, SELinux, accepted tradeoffs
- [Operations](docs/operations.md) — K3s/Helm, provisioning, upgrades, Renovate, alerting, first-time setup
- [Development](docs/development.md) — scripts, config, Compose, validation
- [Decisions](docs/decisions.md) — full NFS, static labels, public geoblock, header-gate removal, accepted duplication
- [Runbooks](docs/runbooks/) — first bootstrap, NFS storage migration

## Rules

- **Provision nodes only via `k3s-server.sh`/`k3s-join.sh`** — no raw installers or ad-hoc joins; those scripts carry the installer and the secret handling. Dev-only lint (`yamllint`/`shellcheck`) changes nothing.
- **Get kubeconfig access through the unlock** — the admin kubeconfig remains root-only (0600); open a dev session with `kubeconfig-unlock.sh` and never restore group/world access or a permanent `KUBECONFIG`.
- Leave `current_target/` alone (runtime state).
- Keep secrets out of git (`config/`, `compose.private.yaml`, `targets/*/compose/.env` are ignored).
- Give new components NetworkPolicies, and set requests/limits from observed usage.
- `nfs-apps` is the default StorageClass; do not add new Longhorn PVs. The old Longhorn system is removed.
- The six user-facing apps (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) have no Authelia forward-auth filter; use `BOOTSTRAP_PRIVATE_APPS` for first-boot LAN/VPN containment.
- Node labels are static: `k3s-server.sh` sets both; `k3s-join.sh --hostpath-main` for a joined node. Do not reintroduce NFD/node-facts.
- Geoblock uses `get.geojs.io`; do not reintroduce the self-hosted GeoIP service/`geoip-src`.
- **Helm charts** — only project-maintained charts; `validate.sh` enforces the allowlist. Home Assistant is the single approved third-party exception. Pin `image.repository`/`image.tag` on app-version-sensitive charts so Renovate tracks the app, not just the chart.
- TLS is `edge-public-tls` (24 exact public SANs) plus `edge-private-tls` (`files`/`traefik`, `websecure` only). Adding a public app means adding its SAN and re-issuing; no per-app certs or wildcards.
