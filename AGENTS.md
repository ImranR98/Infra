# AGENTS.md

Infra is the infrastructure-as-code repo for a multi-machine homelab. Everything a target needs lives in `targets/<t>/`; shared logic sits in `scripts/`; secrets live in the gitignored `config/`. There is no build step in this repo. Target-selecting scripts (`validate`) take `<target>` as their first argument; machine-local scripts (`prereqs`, `renovate`, `preboot`, `wireguard`, `kubeconfig-unlock`, `k3s-server`, `k3s-join`, `restic-restore`) act on the machine they run on.

## Targets

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + public-exposure client Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, public-exposure WireGuard hub, web apps |
| `bigpc` | Compose | Desktop: llama.cpp on AMD RX 9070 (ROCm), FL0W Wine game-save archive agent; syncthing |
| `pc` | Compose | Desktop: ComfyUI/llama.cpp on the Intel Arc iGPU; syncthing |
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
bash scripts/validate.sh srv0         # read-only gate before every deploy
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
helm uninstall srv0-apps -n apps     # delete apps first, then srv0-base

# Compose — from the repo root, ON the target machine, with sudo. Both env
# files are required; the second carries machine facts and COMPOSE_PROFILES.
sudo docker compose \
  --env-file config/vps0/compose.env \
  -f targets/vps0/compose/compose.yaml \
  -f targets/vps0/compose/compose.private.yaml \
  --env-file targets/vps0/compose/.env \
  up -d --remove-orphans
# The same flags work for ps / logs -f <svc> / down <svc> / up -d <svc>.
# First-time setup: bash scripts/init-config.sh <target> [--detect]

# Backups (FL0W scheduled task; manual restore):
bash scripts/restic-restore.sh list
bash scripts/restic-restore.sh pvc <pvc-name> [snapshot] [--live]
bash scripts/restic-restore.sh compose srv0|vps0 [snapshot] [--live]
sudo bash scripts/update-node-ip.sh [--ip X] [--force]

# Machine-local (no target):
bash scripts/prereqs.sh
bash scripts/renovate.sh [apps|infra|all|clear-cache] [--dry-run]   # on-demand
# The scheduled runner is the pure (six-hourly) renovate-daily CronJob:
# app PRs auto-merge via Renovate after test; the following run opens the
# Infra digest PR. Reviewing/merging Infra PRs and deploys are handled by the
# renovate-pr-ops skill. `renovate.sh infra` is the on-demand refresh.
bash scripts/preboot.sh public-exposure|crypt-ssh
bash scripts/wireguard.sh <path/to/wg0.conf>
bash scripts/k3s-server.sh
bash scripts/k3s-join.sh <node_ip> <node_user> \
  [--role agent|server] [--hostpath-main]

# Dev-only lint:
shellcheck $(find scripts targets -name '*.sh')
yamllint -c .yamllint targets/*/config_template \
  targets/srv0/k3s-base/values.yaml targets/srv0/k3s-base/Chart.yaml targets/srv0/k3s-base/files \
  targets/srv0/k3s-apps/values.yaml targets/srv0/k3s-apps/Chart.yaml
```

Scripts warn when the hostname does not match the target; `validate.sh` runs its deploy preconditions (Compose machine-fact `.env`, srv0 state tree and cluster access) only on the target machine. Pass `-y` to PVC commands for non-interactive confirmations.

## Documentation

The guided explorer in `explorer/` is the documentation. Start it with:

```bash
cd explorer
npm install   # first run only
npm run dev
```

Open <http://localhost:4173/>. The tours cover the request path, public edge, WireGuard, apps/data, operations, configuration/decisions, first boot, and maintenance. `explorer/README.md` documents the app itself.

## Resource sizing

Every container picks a tier from `infra.resources` (`_resources.tpl`, duplicated in `k3s-base` and `k3s-apps` because Helm helpers are chart-scoped). Raw `memory:`/`cpu:` keys in a container's `resources:` block are rejected by `validate.sh`.

| Tier | CPU request | Memory request | Memory limit |
|---|---|---|---|
| `tiny` | 10m | 32Mi | 128Mi |
| `small` | 10m | 64Mi | 256Mi |
| `medium` | 25m | 128Mi | 512Mi |
| `large` | 50m | 256Mi | 1Gi |
| `xlarge` | 50m | 512Mi | 2Gi |
| `2xlarge` | 100m | 1Gi | 4Gi |
| `3xlarge` | 250m | 2Gi | 8Gi |

The tiers come from 25 days of cadvisor history (Prometheus in `base`) and are re-derived the same way: memory request = smallest tier at or above the container's 7-day p50, memory limit = 4x that request (bumped a tier if it would fall below the observed peak), CPU request = the tier's value. Totals matter: requests across both charts must stay inside the per-node allocatable (16 CPU / ~30GiB).

Three narrow deviations, each with an inline comment in the template:

- `memLimit` raises the ceiling for a workload whose burst is real but rare (`linkwarden` 16Gi for page-archiving Chromium, `opencode` 4Gi for build spikes). The request still comes from the tier.
- `cpu` overrides the tier's CPU request when CPU and memory disagree (`lifetagger` 1, `syncthing` 500m, `logtfy` 50m).
- `custom` is for memory that tracks a model or cache rather than steady state (`immich-machine-learning` 1Gi/8Gi). It requires explicit `memRequest` and `memLimit`; the helper fails the render without them.

CPU limits stay off unless a chart sets one or the workload takes untrusted input (`crowdsec` 500m, `falco` 1, `prometheus` 1, `logtfy` 1). Don't add one to a normal app: requests don't cap bursts, limits do.

## Rules

- **Provision nodes only via `k3s-server.sh`/`k3s-join.sh`** — no raw installers or ad-hoc joins; those scripts carry the installer and the secret handling. Dev-only lint (`yamllint`/`shellcheck`) changes nothing.
- **Get kubeconfig access through the unlock** — the admin kubeconfig remains root-only (0600); open a dev session with `kubeconfig-unlock.sh` and never restore group/world access or a permanent `KUBECONFIG`.
- Leave `~/infra_state/` alone (runtime state). It holds `compose_live_state/` and `k3s_live_state/`.
- Keep secrets out of git (`config/`, `compose.private.yaml`, `targets/*/compose/.env` are ignored).
- Give new components NetworkPolicies, and pick their requests/limits from the tier ladder above (never ad-hoc numbers).
- **`nfs-apps` is the default StorageClass for shared/bulk data; `local-apps` is its local twin** — same `<namespace>/<pvc>` layout under `~/infra_state/k3s_live_state/app-data`, mounted from the host filesystem instead of NFS, `ReadWriteOnce`, provisioned by the dedicated `local-path-provisioner` instance on the `hostpath-main` node (pinned by `infra.local/hostpath-main`, never by hostname). Use `local-apps` for SQLite and any single-node app that needs a real filesystem; use `nfs-apps` for RWX bulk data. Postgres and the observability stores (Loki, Prometheus) remain on `nfs-apps` with the measured NFS cost accepted. Add no other dynamic PVs; the static `hostpath` claims remain the only exception.
- The six user-facing apps (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) have no Authelia forward-auth filter; use `BOOTSTRAP_PRIVATE_APPS` for first-boot LAN/VPN containment.
- **srv0 is the only K3s node** — bigpc is Compose-only (llama.cpp, the FL0W Wine game-save archive agent, syncthing). There are no node-role labels. `k3s-server.sh` sets `infra.local/hostpath-main=true` and `infra.local/external-exposed=true` on srv0; `k3s-join.sh --hostpath-main` labels a replacement Main-data node.
- **HostPath data is exposed through a local PV/PVC** — app data that lives on a host path must be mounted via a statically bound `hostpath` PV/PVC whose `nodeAffinity` names the node that owns the path (`infra.local/hostpath-main` for the Main tree) so the claim pins the pod. Never add a pod `nodeSelector` to compensate for a raw `hostPath`; device/system paths (`/dev`, `/run/dbus`, `/var/lib/kubelet`) are exempt. `hostpath-main` is a singleton: exactly one node owns the Main tree and `~/infra_state`; `k3s-join.sh --hostpath-main` replaces that owner. Bigpc's AI data is host-local Compose data under `~/ai`, not a cluster PV.
- **Hardware is requested through the generic device plugin** — use `infra.local/intel-gpu`, `infra.local/amd-igpu`, `infra.local/amd-dgpu`, `infra.local/vaapi`, or `infra.local/conbee` rather than a node label as a hardware proxy. The plugin generates resources from sysfs and `/dev` at startup; device paths are normalized to `renderD128`/`ttyACM0`. The extended resource is the only hardware selector.
- **Accelerator selection is config, not chart edits** — `GPU_PROFILE` (`intel|amd|none`) chooses the media/ML backends; per-app overrides (`FRIGATE_DETECTOR`, `IMMICH_ML_BACKEND`, `IMMICH_ML_GPU_RESOURCE`, `JELLYFIN_HWACCEL`, `IMMICH_SERVER_HWACCEL`) exist for mixed/fallback cases. On the current AMD board Frigate and Immich ML both use `infra.local/amd-igpu`; Phoenix-class iGPUs need `IMMICH_ML_HSA_OVERRIDE_GFX_VERSION=11.0.0` or the CLIP text model segfaults the ML worker. Frigate is srv0-only. `HA_CONBEE`/`HA_BLUETOOTH` gate the HA hardware mounts.
- **LLM models are cache-managed** — llama.cpp runs in Compose on bigpc, with `LLAMA_CACHE` at `~/ai/llama`; download/delete through the built-in Models UI at `models.<SERVICES_DOMAIN>` (srv0 Traefik forwards to the host through a selectorless `llama-cpp` Service + EndpointSlice at `BIGPC_HOST`). The pc Compose stack uses the same shared layout under `~/ai` (`~/ai/comfyui`, `~/ai/llama`); its router scans `~/ai/llama` and writes UI downloads to `~/ai/llama/.cache` (loopback UI at `127.0.0.1:18080`). Do not add `--models-preset` or manual GGUF paths to either router: preset sections are listed as models even after their files are gone, and only cache models are deletable through the UI. New cache models inherit the global Q8 KV, Flash Attention, and CPU-projector settings and auto-fit their context with `--fit`.
- Geoblock uses `get.geojs.io`.
- **Renovate splits app and Infra** — app repos extend `renovate-preset.json`; Renovate auto-merges non-major app updates after the `test` check once the **3-day** `minimumReleaseAge` passes (`internalChecksFilter: strict` holds updates until eligible; `timestamp-required` means an update without a release timestamp is not eligible), while majors wait on the Dependency Dashboard. Infra image refs use immutable version tags and wait the same 3 days. The sole image-age exception is the narrow allowlist in `renovate.json`: first-party `ghcr.io/imranr98/**` app images (`:latest@sha`, opened on the next run after publish), plus channel-only images that publish no immutable tag (`lscr.io/linuxserver/**`, `ghcr.io/reliq-hq/comfyui`, `ghcr.io/ggml-org/llama.cpp`, and the Bitnami DB/kubectl pins). Infra Renovate PRs are never auto-merged; the `renovate-pr-ops` skill researches, validates, and presents them for approval. Never hand-pin an app digest. If a non-allowlisted image stays pending for more than 3 days, it is being rebuilt faster than the age gate: pin an immutable version tag or add a well-justified allowlist entry. `scripts/check-images.sh` enforces the tag/digest policy. The repo list (Infra + apps) lives in `config/srv0/values.yaml` and feeds both the CronJob and local runs. No app checkout is assumed; use the GitHub API or a temporary clone.
- **Helm charts** — only project-maintained charts; `validate.sh` enforces the allowlist. Home Assistant is the single approved third-party exception. Pin `image.repository`/`image.tag` on app-version-sensitive charts so Renovate tracks the app, not just the chart.
- TLS is `edge-public-tls` (exact SANs from `PUBLIC_HOSTS`) plus `edge-private-tls` (`PRIVATE_HOSTS`, `websecure` only). Adding a public app means adding its label to `PUBLIC_HOSTS` and its route, then re-issuing; no per-app certs or wildcards.
- **Authelia access control is dual-source** — structural bypasses and the final admin catch-all stay in the charts; group/user/deployment-specific rules live in `config/` (`AUTHELIA_ACCESS_CONTROL_RULES` on srv0; `config/vps0/authelia/access_control.yml` rendered by `scripts/render-vps0-authelia.sh` on vps0). Don't add personal group names to the chart.
