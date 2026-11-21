# Apps

All app workloads are listed here so the platform layers stay separate from the
inventory.

## srv0 (K3s)

| Area | Apps | Exposure |
|---|---|---|
| Personal | Home Assistant (`ha`), Immich (`immich`), Jellyfin (`tv`), Linkwarden (`links`), Navidrome (`music`), Nextcloud (`nextcloud`), Opodsync (`opodsync`) | Public + LAN/VPN; no Authelia forward-auth |
| Media | Frigate (`frigate`), Mosquitto, go2rtc consumer | Public/private as configured |
| *arr stack | Prowlarr, qBittorrent, Radarr, Sonarr, Seerr, Flaresolverr | Public with app auth; qBittorrent has its own WireGuard sidecar |
| Reading/files | FreshRSS (`rss`), FileBrowser (`files`), Plik (`send`) | `files` is private-only |
| AI/tools | Open WebUI (`gpt`), OpenCode (`opencode`), llama.cpp endpoint (`models`) | App auth / Authelia; `models` forwards to bigpc |
| D4TA | Dashboard + D$CPLN, W@TXT, FL0W, TAG5, Lockdown | `data.<SERVICES_DOMAIN>` |
| Tracking | FMD (`fmd`), FMD Stats (`fmdstats`) | Public |
| Support | Syncthing, ntfy, Headlamp, Grafana, CrowdSec UI, Logtfy, Renovate, observability | See the linked pages |

The six user-facing apps (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome,
Opodsync) deliberately rely on their own auth. `BOOTSTRAP_PRIVATE_APPS` keeps them
LAN/VPN-only during first boot.

### D4TA (multi-module suite)

D4TA is the current multi-module suite: one host, one config checkout.
`data.<SERVICES_DOMAIN>` serves the dashboard and all modules
(`/dscpln`, `/watxt`, `/flow`, `/tags`, `/lockdown`). The app repo publishes the
`d4ta-*` images and a standalone Helm chart; `srv0-apps` consumes it as an OCI
dependency. The private config is one `d4ta-config` checkout at `D4TA_CONFIG_PATH`;
do not reintroduce the old per-app hosts/deployment names.

## vps0 (Compose)

| App | Exposure |
|---|---|
| Obtainium Apps | `apps.obtainium.<BASE_SERVICES_DOMAIN>` |
| MeTube | `ytdl.<CLOUD_SERVICES_DOMAIN>` |
| IKOM | `ikom.<CLOUD_SERVICES_DOMAIN>` (redirects from the base domain) |
| Attention Game | `attentiongame.<CLOUD_SERVICES_DOMAIN>` |
| Our Times | `times.<CLOUD_SERVICES_DOMAIN>` |
| Sale site | `sale`, `home.sale`, `tech.sale` |
| Owncast + auth | `owncast.<CLOUD_SERVICES_DOMAIN>` |
| PixelNtfy | `pixelntfy.<CLOUD_SERVICES_DOMAIN>` |
| ISBN Lookup | `isbn.<CLOUD_SERVICES_DOMAIN>` |
| Plausible analytics | `plausible.<BASE_SERVICES_DOMAIN>` |
| Shlink + web client | `ln.<BASE_SERVICES_DOMAIN>`, `ui.ln.<CLOUD_SERVICES_DOMAIN>` |
| sb25 | private app from `compose.private.yaml` |
| D4TA agent | host-network archive agent, `:8788` |

## Satellites

- **bigpc**: llama.cpp ROCm router on `:8080` (reached through the srv0
  `models.<SERVICES_DOMAIN>` route), D4TA Wine game-save agent on `:8788`, Syncthing.
- **pc**: llama.cpp SYCL router loopback `127.0.0.1:18080`, Syncthing. ComfyUI is
  committed but commented out; see below.
- **rpi**: go2rtc RTSP `:8554`, loopback UI `127.0.0.1:1984`, consumed by Frigate.

## Backup labels

PVCs labelled `auto-backup: "true"` are copied by the D4TA backup task. Use
`backup.infra/exclude` for rebuildable caches (logs, thumbnails, model caches).
Frigate recordings and other replaceable bulk media are deliberately not labelled.
See [Platform: storage](platform.md#storage).

## Adding an app

1. Add a Deployment/StatefulSet template in `targets/srv0/k3s-apps/templates/` or a
   Compose service in the target's `compose.yaml`.
2. Pick resources from the tier ladder and request hardware via
   `infra.local/*` if needed.
3. Add ingress (`HTTPRoute` or Traefik labels), then add the host to
   `PUBLIC_HOSTS`/`PRIVATE_HOSTS` if it needs an edge certificate.
4. Add NetworkPolicies for pod-to-pod access.
5. Label persistent app state `auto-backup: "true"` and exclude rebuildable caches.
6. Pin images by immutable tag/digest; let Renovate manage upgrades.
7. Run `bash scripts/validate.sh <target>` and deploy through
   [Operations: deploy](operations.md#deploy).

## Frigate model

Frigate downloads `yolov9-t-320.onnx` from the `frigate-model-v1` GitHub Release at pod
start, verifies its SHA-256, and caches it on the config PVC. The build recipe lives
in `targets/srv0/assets/README.md`. The ONNX file itself is gitignored.

## Optional ComfyUI on pc

The ComfyUI service is intentionally kept commented out in
`targets/pc/compose/compose.yaml`. If enabled, it uses the Intel Arc iGPU, exposes
`127.0.0.1:8188`, and stores models/state under `~/ai/comfyui`. It is not part of the
current running set.
