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
# First time only — run scripts/prereqs.sh on each machine first (it installs
# yq), then copy templates (never overwrites) and detect srv0 hardware:
bash scripts/init-config.sh srv0 --detect
bash scripts/init-config.sh vps0

# Preflight — read-only, any machine:
bash scripts/validate.sh srv0
bash scripts/validate.sh vps0

# K3s (srv0) — the kubeconfig is root-only. Unlock it in another terminal:
bash scripts/kubeconfig-unlock.sh
bash scripts/deploy.sh srv0          # validate + base/apps + rollout checks
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
helm uninstall srv0-apps -n apps     # delete apps first, then srv0-base

# Compose — from the repo root, ON the target machine. The wrapper supplies
# the config env, generated machine facts, private overlay, Compose profiles,
# and (for vps0) renders Authelia before `up`.
bash scripts/compose.sh vps0 up -d
bash scripts/compose.sh vps0 down <svc>                         # then up -d <svc>
bash scripts/compose.sh vps0 up -d --force-recreate --no-deps <svc>
bash scripts/compose.sh srv0 up -d                              # public-exposure client
bash scripts/compose.sh pc up -d
# `deploy.sh <target>` runs validate + the appropriate Compose/Helm flow.
# First-time setup: bash scripts/init-config.sh <target> [--detect]

# Backups (Task Runner scheduled task; manual restore):
bash scripts/restic-restore.sh list
bash scripts/restic-restore.sh pvc <pvc-name> [snapshot] [--live]
bash scripts/restic-restore.sh compose srv0|vps0 [snapshot] [--live]
sudo bash scripts/update-node-ip.sh [--ip X] [--force]

# Machine-local (no target):
bash scripts/prereqs.sh
bash scripts/renovate.sh [apps|infra|all|clear-cache] [--dry-run]   # on-demand
# The scheduled runner is the pure (six-hourly) renovate-daily CronJob:
# app PRs auto-merge via Renovate after test; Infra PRs are the manual gate,
# handled by the renovate-pr-ops skill (which waits for app publishes and
# triggers the on-demand renovate-infra Job).
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

The guided explorer in `explorer/` is the documentation. Start it with:

```bash
cd explorer
npm install   # first run only
npm run dev
```

Open <http://localhost:4173/>. The tours cover the request path, public edge, WireGuard, apps/data, operations, configuration/decisions, first boot, and maintenance. `explorer/README.md` documents the app itself.

## Rules

- **Provision nodes only via `k3s-server.sh`/`k3s-join.sh`** — no raw installers or ad-hoc joins; those scripts carry the installer and the secret handling. Dev-only lint (`yamllint`/`shellcheck`) changes nothing.
- **Get kubeconfig access through the unlock** — the admin kubeconfig remains root-only (0600); open a dev session with `kubeconfig-unlock.sh` and never restore group/world access or a permanent `KUBECONFIG`.
- Leave `current_target/` alone (runtime state).
- Keep secrets out of git (`config/`, `compose.private.yaml`, `targets/*/compose/.env` are ignored).
- Give new components NetworkPolicies, and set requests/limits from observed usage.
- `nfs-apps` is the default StorageClass; do not add new Longhorn PVs. The old Longhorn system is removed.
- The six user-facing apps (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) have no Authelia forward-auth filter; use `BOOTSTRAP_PRIVATE_APPS` for first-boot LAN/VPN containment.
- Node labels are static: `k3s-server.sh` sets both; `k3s-join.sh --hostpath-main` for a replacement Main-data node (only one node may carry it). Do not reintroduce NFD/node-facts.
- **HostPath data is exposed through a local PV/PVC** — app data that lives on a host path must be mounted via a statically bound `hostpath` PV/PVC whose `nodeAffinity` names the node that owns the path (`infra.local/hostpath-main` for the Main tree; `kubernetes.io/hostname` for a node-local path such as the D$CPLN archive agent) so the claim pins the pod. Never add a pod `nodeSelector` to compensate for a raw `hostPath`; device/system paths (`/dev`, `/run/dbus`, `/var/lib/kubelet`) are exempt. `hostpath-main` is a singleton: exactly one node owns the Main tree; `k3s-join.sh --hostpath-main` replaces that owner, it does not add a second.
- **Hardware is requested through the generic device plugin** — use `infra.local/intel-gpu`, `infra.local/amd-igpu`, `infra.local/amd-dgpu`, `infra.local/vaapi`, or `infra.local/conbee` rather than a node label as a hardware proxy. The plugin generates resources from sysfs and `/dev` at startup; device paths are normalized to `renderD128`/`ttyACM0`.
- **Accelerator selection is config, not chart edits** — `GPU_PROFILE` (`intel|amd|none`) chooses the media/ML backends; per-app overrides (`FRIGATE_DETECTOR`, `IMMICH_ML_BACKEND`, `JELLYFIN_HWACCEL`, `IMMICH_SERVER_HWACCEL`, `OLLAMA_GPU`) exist for mixed/fallback cases. `HA_CONBEE`/`HA_BLUETOOTH` gate the HA hardware mounts.
- Geoblock uses `get.geojs.io`; do not reintroduce the self-hosted GeoIP service/`geoip-src`.
- **Renovate splits app and Infra** — app repos extend `renovate-preset.json`; Renovate auto-merges non-major app updates after the `test` check, while majors wait on the Dependency Dashboard. Infra Renovate PRs are never auto-merged: the `renovate-pr-ops` skill merges app exceptions, waits for the app `publish` job, triggers the on-demand `renovate-infra` Job, and presents Infra PRs for approval. No app checkout is assumed; use the GitHub API or a temporary clone.
- **Helm charts** — only project-maintained charts; `validate.sh` enforces the allowlist. Home Assistant is the single approved third-party exception. Pin `image.repository`/`image.tag` on app-version-sensitive charts so Renovate tracks the app, not just the chart.
- TLS is `edge-public-tls` (exact SANs from `PUBLIC_HOSTS`) plus `edge-private-tls` (`PRIVATE_HOSTS`, `websecure` only). Adding a public app means adding its label to `PUBLIC_HOSTS` and its route, then re-issuing; no per-app certs or wildcards.
- **Authelia access control is dual-source** — structural bypasses and the final admin catch-all stay in the charts; group/user/deployment-specific rules live in `config/` (`AUTHELIA_ACCESS_CONTROL_RULES` on srv0; `config/vps0/authelia/access_control.yml` rendered by `scripts/render-vps0-authelia.sh` on vps0). Don't add personal group names to the chart.
