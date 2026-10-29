# Architecture

## Targets

`targets/` is authoritative — the table below can drift.

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + public-exposure client Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, public-exposure WireGuard hub, web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm) via agent node; syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

- **srv0** — k3s-base: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, traefik, crowdsec, crowdsec-web-ui, falco, authelia, ntfy, descheduler, system-upgrade, monitoring, generic-device-plugin, remote-access-amneziawg, remote-access-dns. k3s-apps: immich, logtfy, jellyfin, navidrome, dscpln-file-pipelines, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, prowlarr, qbittorrent, radarr, seerr, sonarr, dscpln-agent, dscpln-portal, dscpln-balance-xlsx, dscpln-task-runner, dscpln-lockdown, opencanary, flaresolverr, fmd, plik, filebrowser, dscpln-whatsapp-txt, syncthing, headlamp, frigate, opencode, guacamole. The Compose sidecar is the public-exposure WireGuard client. Ollama runs on bigpc's AMD GPU; Open WebUI and the in-cluster opencode agent reach it in-cluster only (no LAN exposure), with the agent's provider endpoint chart-owned in `/etc/opencode/opencode.jsonc`. Jellyfin and Immich server use the vendor-neutral `infra.local/vaapi` resource; Frigate uses `intel-gpu` (OpenVINO) or `amd-igpu` (ROCm); Immich ML uses `intel-gpu` (OpenVINO) or bigpc's `amd-dgpu` (ROCm), with CPU fallbacks. `GPU_PROFILE` (`intel|amd|none`) selects the media/ML backends. Frigate recordings and the Jellyfin libraries stay on NFS. Home Assistant's integration auto-installs on every pod start (no HACS). A full-tunnel AmneziaWG VPN server (host-network pod running the userspace amneziawg-go implementation) is exposed publicly as `vps0:51820/udp`, DNAT'd over the public-exposure tunnel, with the `remote-access-dns` pod resolving `*.$SERVICES_DOMAIN` names to the tunnel address so services keep working by their normal URLs; FileBrowser serves the host Main tree at `files.$SERVICES_DOMAIN` over the VPN and LAN, never public (OIDC via Authelia; sessions signed with the key v2 persists in its SQLite DB), and a `conn-notify` sidecar alerts ntfy when a client connects (see `docs/networking.md`). opencode is a sandboxed in-cluster agent (`targets/srv0/k3s-apps/opencode.yaml`): a derived Debian trixie image (`ImranR98/opencode-sandbox`, the glibc opencode v2 binary plus a core dev toolchain, nvm/Node, and a Homebrew seed) running as UID 1000, whose only mounts are an NFS home PVC (`~/.opencode`, config, MCPs, auth, sessions), an unbacked NFS tools PVC (`/home/linuxbrew`: Homebrew + nvm/Node versions), and the `Main/Code/sandbox` NFS share, so it cannot touch the rest of the host; `opencode.$SERVICES_DOMAIN` is public behind geoblock + crowdsec + Authelia.
- **bigpc** — K3s agent; the generic-device-plugin advertises the RX 9070 as `infra.local/amd-dgpu`, the Radeon 610M as `infra.local/amd-igpu`, and the preferred VAAPI node as `infra.local/vaapi`. The generic D$CPLN archive agent (`dscpln-agent-bigpc`) runs here, pinned by its local data PV. Tainted `scheduling-discouraged` (PreferNoSchedule). Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host network).

### Accelerators

| Node | GPU | Resource(s) | Consumers |
|---|---|---|---|
| `srv0` (current) | Intel Iris Xe | `intel-gpu`, `vaapi`, `conbee` | Frigate/Immich ML (OpenVINO), Jellyfin/Immich server (VAAPI), HA (ConBee) |
| `srv0` (after board swap) | AMD Radeon 780M | `amd-igpu`, `vaapi`, `conbee` | Frigate (ROCm), Jellyfin/Immich server (VAAPI), HA (ConBee) |
| `bigpc` | RX 9070 + Radeon 610M | `amd-dgpu`, `amd-igpu`, `vaapi` | Ollama, Immich ML (ROCm), optional Frigate fallback |
| `pc` | Compose only | none | no K3s device resources |

The device plugin generates these from sysfs and `/dev`; it normalizes host
`renderD*`/`card*`/`ttyACM*` names to `renderD128`/`card0`/`ttyACM0`. The
hardware swap runbook is `docs/runbooks/hardware-swap.md`.
- **vps0** — Compose runs public-exposure-server-wg + public-exposure-watch, traefik, traefik-logrotate, authelia + db, crowdsec, crowdsec-web-ui, plausible (app/ClickHouse/Postgres/state-fixperms), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, our-times, sale-site, obtainium, attentiongame, dscpln-agent, and socket proxies. No watchtower here — Renovate owns every image (floating tags pinned by digest). Two zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`). Unused Docker images are pruned monthly by a systemd timer installed from `targets/vps0/docker-prune/`.
- **rpi** — go2rtc runs the official image untouched; a one-shot `go2rtc-init` service generates the stream password on first start and persists it in `current_target/compose_live_state/go2rtc/` (`password` file + `go2rtc.env`, consumed via compose `env_file`); the WebUI is loopback-only. `prereqs.sh` on rpi is a one-time machine bootstrap (Docker install + the go2rtc state bind dir owned by `$MY_UID`) — no `config_template/` and no machine-fact needs.

## Directory layout

```
.gitignore                    # ignores current_target/, backups, config/,
                              #   targets/*/compose/{compose.private.yaml,.env}
.yamllint                     # lint config for the config templates + k3s chart YAML
renovate.json                 # Renovate repo config
scripts/                      # common.sh (env bootstrap + helpers) + the ops scripts
docs/                         # architecture/networking/storage/security/operations/development/decisions + runbooks
config_template/VARS.env      # committed template for config/VARS.env (universal secrets)
config/                       # gitignored real values, mirroring targets/<t>/config_template/:
                              #   VARS.env, srv0/{values.yaml,compose.env,public-exposure/},
                              #   vps0/{compose.env,public-exposure/,authelia/{users_database,access_control}.yml,
                              #   dscpln-agent/agent.json}
targets/<t>/
  config_template/            # every required variable + generation command; init-config.sh copies it
  compose/                    # compose.yaml, optional gitignored compose.private.yaml,
                              #   files/ (verbatim :ro configs), .env (generated machine facts)
  k3s-base/ k3s-apps/         # srv0 Helm charts; k3s-base carries files/ (generic-device-plugin
                              #   config, alerting, dashboards, AmneziaWG scripts) and the
                              #   nfs-server source; k3s-apps carries the app manifests
current_target/compose_live_state/   # gitignored Compose runtime state
current_target/k3s_live_state/       # gitignored K3s/NFS app-data state (nfs-apps/)
state_backups/restic/                 # gitignored restic repository (Syncthing tree)
architecture.svg|.excalidraw  # architecture diagram
```

## Bootstrap order

For the full walkthrough, use `docs/runbooks/first-boot.md`. In short:

1. **DNS first** — point `SERVICES_DOMAIN`/`*.$SERVICES_DOMAIN`,
   `CLOUD_SERVICES_DOMAIN`/`*.$CLOUD_SERVICES_DOMAIN`, and any base-domain
   apps at vps0. When `SERVICES_DOMAIN=home.$BASE_SERVICES_DOMAIN`, the vps0
   file-provider routes `home.$BASE_SERVICES_DOMAIN` and
   `*.home.$BASE_SERVICES_DOMAIN`. cert-manager uses HTTP-01, so it cannot
   issue until vps0 is serving.
2. **`scripts/prereqs.sh` on every machine** — packages (NFS client), pinned
   Helm, Docker, the machine-fact `.env`, host bind dirs, and `acme.json`.
3. **Config** — `bash scripts/init-config.sh <target> [--detect]` and fill
   every value; only `MAIN_PARENT_DIR`/`SECONDARY_STORAGE_PATH` are required
   roots, the rest derive. See `docs/configuration.md`.
4. **Tunnel material** — fill `config/srv0/compose.env`, run
   `scripts/public-exposure-keygen.sh` on srv0, copy
   `config/vps0/public-exposure/` to vps0, and install `preboot.sh`.
5. **Bring vps0 up before srv0** — `scripts/deploy.sh vps0` renders Authelia
   and runs Compose; srv0's ACME challenges need the edge serving.
6. **srv0** — `preflight-task-runner.sh --fix` if using D$CPLN, then
   `k3s-server.sh` → `kubeconfig-unlock.sh` → `compose.sh srv0 up -d` →
   `deploy.sh srv0`. Set `BOOTSTRAP_PRIVATE_APPS: "true"` for the first boot;
   the six user-facing apps stay LAN/VPN-only until Authelia is Ready, then
   set it back to `"false"` and redeploy.
7. **Add the other nodes** — `k3s-join.sh` for bigpc; deploy `pc`, `bigpc`,
   and `rpi` with `deploy.sh`. `--hostpath-main` is a singleton for srv0;
   `--scheduling-discouraged` adds the desktop taint.
8. **Machine-local extras** — `wireguard.sh`, `preboot.sh`.
9. **Post-deploy** — the manual first-time setup below (app seeding,
   crowdsec-web-ui machine registration, VPN profiles).

The `renovate-daily` job mounts this repo from `INFRA_ROOT`, so the checkout can live anywhere (it need not be under `MAIN_PARENT_DIR/Main`). Task Runner instead mounts the private `dscpln-config` checkout at `$MAIN_PARENT_DIR/Main/Code/Automation/dscpln-config`.
