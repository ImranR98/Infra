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

- **srv0** — k3s-base: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, traefik, crowdsec, crowdsec-web-ui, falco, authelia, ntfy, descheduler, system-upgrade, monitoring, generic-device-plugin, remote-access-amneziawg, remote-access-dns. k3s-apps: immich, logtfy, jellyfin, navidrome, file-pipelines, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, dscpln, task-runner, lockdown, opencanary, flaresolverr, fmd, plik, filebrowser, whatsapp-txt-browser, syncthing, headlamp, frigate, opencode, guacamole. The Compose sidecar is the public-exposure WireGuard client. Ollama runs on bigpc's AMD GPU; Open WebUI and the in-cluster opencode agent reach it in-cluster only (no LAN exposure), with the agent's provider endpoint chart-owned in `/etc/opencode/opencode.jsonc`. Jellyfin, Immich ML and Frigate use srv0's Iris Xe iGPU; Frigate recordings stay on NFS deliberately so the pod can move nodes. Home Assistant's integration auto-installs on every pod start (no HACS). A full-tunnel AmneziaWG VPN server (host-network pod running the userspace amneziawg-go implementation) is exposed publicly as `vps0:51820/udp`, DNAT'd over the public-exposure tunnel, with the `remote-access-dns` pod resolving `*.$SERVICES_DOMAIN` names to the tunnel address so services keep working by their normal URLs; FileBrowser serves the host Main tree at `files.$SERVICES_DOMAIN` over the VPN and LAN, never public (OIDC via Authelia; sessions signed with the key v2 persists in its SQLite DB), and a `conn-notify` sidecar alerts ntfy when a client connects (see `docs/networking.md`). opencode is a sandboxed in-cluster agent (`targets/srv0/k3s-apps/opencode.yaml`): a derived Debian trixie image (`ImranR98/opencode-sandbox`, the glibc opencode v2 binary plus a core dev toolchain, nvm/Node, and a Homebrew seed) running as UID 1000, whose only mounts are an NFS home PVC (`~/.opencode`, config, MCPs, auth, sessions), an unbacked NFS tools PVC (`/home/linuxbrew`: Homebrew + nvm/Node versions), and the `Main/Code/sandbox` NFS share, so it cannot touch the rest of the host; `opencode.$SERVICES_DOMAIN` is public behind geoblock + crowdsec + Authelia.
- **bigpc** — K3s agent; the generic-device-plugin advertises the AMD GPU as `infra.local/amd`. Tainted `scheduling-discouraged` (PreferNoSchedule). Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host network).
- **vps0** — Compose runs public-exposure-server-wg + public-exposure-watch, traefik, traefik-logrotate, authelia + db, crowdsec, crowdsec-web-ui, plausible (app/ClickHouse/Postgres/state-fixperms), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, our-times, sale-site, obtainium, attentiongame, and socket proxies. No watchtower here — Renovate owns every image (floating tags pinned by digest). Two zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`). Unused Docker images are pruned monthly by a systemd timer installed from `targets/vps0/docker-prune/`.
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
                              #   vps0/{compose.env,public-exposure/,authelia/users_database.yml}
targets/<t>/
  config_template/            # every required variable + generation command (copy to config/<t>/)
  compose/                    # compose.yaml, optional gitignored compose.private.yaml,
                              #   files/ (verbatim :ro configs), .env (machine facts, from prereqs.sh)
  k3s-base/ k3s-apps/         # srv0 Helm charts; k3s-base carries files/ (generic-device-plugin
                              #   config, alerting, dashboards, AmneziaWG scripts) and the
                              #   nfs-server source; k3s-apps carries the app manifests
current_target/compose_live_state/   # gitignored Compose runtime state
current_target/k3s_live_state/       # gitignored K3s/NFS app-data state (nfs-apps/)
state_backups/restic/                 # gitignored restic repository (Syncthing tree)
architecture.svg|.excalidraw  # architecture diagram
```

## Bootstrap order

For a from-scratch setup:

1. **DNS first** — `$SERVICES_DOMAIN` must point at vps0, with `home.$SERVICES_DOMAIN` and `*.home.$SERVICES_DOMAIN` for the tunnel; run `scripts/public-exposure-keygen.sh` on srv0 and copy `config/vps0/public-exposure/` to vps0 (the template documents it). cert-manager uses HTTP-01, so it cannot issue certs until the public path through the vps0 hub exists.
2. **`scripts/prereqs.sh` on every machine** — packages (NFS client), pinned helm, Docker, the machine-fact `.env`, host bind dirs, and the seeded `acme.json`.
3. **Config** — `cp -r targets/<t>/config_template config/<t>` and fill every value; `cp config_template/VARS.env config/VARS.env`; point `INFRA_ROOT`, `MAIN_PARENT_DIR`, `MEDIA_DIR_PATH` etc. at the machine layout.
4. **Bring vps0 up before srv0** — `validate.sh vps0`, then compose up: srv0's ACME challenges need the edge already serving.
5. **srv0** — `validate.sh srv0` → `k3s-server.sh` → `kubeconfig-unlock.sh` → the public-exposure client compose sidecar → `srv0-base` → `srv0-apps`. On a first bootstrap, set `BOOTSTRAP_PRIVATE_APPS: "true"` in `config/srv0/values.yaml`; the six user-facing apps stay on the LAN/VPN listener until Authelia is Ready, then set it back to `"false"`.
6. **Add the other nodes** — run `k3s-join.sh` on the control plane once the nfs-server/csi-driver are up. `--hostpath-main` labels a node that owns the Main host paths; `--scheduling-discouraged` adds the desktop taint.
7. **Machine-local extras** — `wireguard.sh`, `preboot.sh`.
8. **Post-deploy** — the manual first-time setup below (app seeding, crowdsec-web-ui machine registration).

The `renovate-daily` job mounts this repo from `INFRA_ROOT`, so the checkout can live anywhere (it need not be under `MAIN_PARENT_DIR/Main`). Task Runner instead mounts the private `dscpln-config` checkout at `$MAIN_PARENT_DIR/Main/Code/Automation/dscpln-config`.
