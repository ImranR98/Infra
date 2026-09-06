# AGENTS.md

Infra is a shell-driven IaC repo for a multi-machine homelab. One CLI — `./infra.sh <target> <command>` — dispatches commands against named machines. No build step, no agent: bash scripts + envsubst, run on the machine being managed. Audience assumed to know Docker/Compose, Kubernetes, Traefik.

## Prerequisites

Bash 4+, Docker Compose v2, kubectl (K3s targets), yq, envsubst, jq, curl, python3. Node.js/npm and `go` for local `renovate` runs (npx + gomod manager). Install: `./infra.sh <target> prereqs` (detects apt/dnf/rpm-ostree; Docker from official repos).

## Targets

`targets/` is authoritative — the list below is current but may drift.

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + frpc Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, FRP server (frps), web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm) via agent node; syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

Each target dir: `VARS.template.sh` (committed; documents every required `export` + generation commands), optional `compose/` and/or `k3s/`, optional `commands/` overrides.

Notable per-target facts:
- **srv0** — `base` group: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring, cdi-specs. `apps`: immich, logtfy, jellyfin, navidrome, mdscl, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, dscpln, opencanary, flaresolverr, fmd, plik, syncthing, headlamp, frigate (see `k3s/groups.yaml`). Compose sidecar = frpc only. Ollama runs on the `bigpc` agent (RX 9070/ROCm); Open WebUI reaches it in-cluster only (no LAN exposure). Jellyfin/Immich ML/Frigate use srv0's Iris Xe iGPU; Frigate recordings stay on NFS deliberately so the pod can move nodes. Home Assistant integration auto-installs on every pod start (no HACS).
- **bigpc** — K3s agent labelled `has-amdgpu=true`, tainted `scheduling-discouraged` (PreferNoSchedule), no Longhorn replicas (`create-default-disk=false`); Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host net).
- **vps0** — Compose: frps, traefik, authelia + db, crowdsec, plausible (app/ClickHouse/Postgres/init), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, cct26, moving-sale, obtainium, socket proxies. No watchtower — all vps0 images are Renovate-owned (floating tags digest-pinned). Two domain zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`).
- **rpi** — single go2rtc container; stream password auto-generated on first start and persisted in `current_target/compose_live_state/go2rtc/password`; WebUI loopback-only.

## Essential commands

```
./infra.sh <target> validate                          # YAML + kustomize + var-reference + compose config checks
./infra.sh <target> list-domains                      # Host(...) domains from IngressRoutes & Compose
./infra.sh <target> compose install                   # Render templates, create host dirs, up -d
./infra.sh <target> compose restart <service>         # Re-render templates, down+up one service
./infra.sh <target> compose backup-state [remote]
./infra.sh <target> compose generate-mtls-certs <server-target>   # mTLS CA/certs for a client↔server pair
./infra.sh <target> k3s setup                         # Bootstrap a K3s control-plane node
./infra.sh <target> k3s join <ip> <user> [agent|server]
./infra.sh <target> k3s group base|apps apply|delete
./infra.sh <target> k3s deploy <component> [apply|delete|diff|yaml]
./infra.sh <target> k3s update-node-ip [--ip X] [--force]
./infra.sh <target> k3s test-storage <size>           # NFS PV/PVC/pod write-read smoke test
./infra.sh <target> k3s backup-pvc <name>|--all [-y]
./infra.sh <target> k3s restore-pvc <name>|--all [-y]
./infra.sh <target> k3s pvc-shell <pvc>               # Temp pod mounting a Longhorn PVC + hostPath, drop into shell
./infra.sh <target> wireguard <config-path>
./infra.sh renovate [--dry-run]                     # Universal: run Renovate — opens update PRs on GitHub
```

srv0 only: `k3s test services` — browser-based integration tests for all exposed services (`targets/srv0/commands/k3s/test/`).

## Dispatch system

Two modes, chosen by `infra.sh` from the first argument: a directory under `targets/` → **target mode** (everything below); otherwise a top-level entry in `commands/` (`.sh`/`.py`/dir) → **universal mode** (no target). Anything else → error listing both targets and universal commands.

`infra_dispatch()` (`lib/dispatch.sh`) walks the argument list as directory levels. Per argument it checks, in order:
1. `targets/<target>/commands/<path>/<arg>.sh|.py|/` — target override (target mode only)
2. `commands/<path>/<arg>.sh|.py|/` — global default (universal commands; also reachable under a target)

`.sh` must be `chmod +x` (run via bash); `.py` runs via python3. The first script found is `exec`'d with the remaining args (it replaces the infra.sh process). `validate` and `list-domains` are built-ins handled inside dispatch (target mode only).

Startup sequence (`infra.sh`): sets `INFRA_ROOT`, `INFRA_INTERACTIVE`, state dirs; detects target vs universal mode; target mode: if `hostname` ≠ target, warns (and prompts, when interactive); sources `lib/common.sh` (idempotent via `INFRA_LIB_LOADED`, pulls in pkg/env/net/k3s/compose/validate/pvc modules); resolves and sources the VARS file (skipped for `compose generate-mtls-certs`); sets `MY_UID` and `DOCKER_GID` for compose commands (except `backup-state`/`generate-mtls-certs`). Universal mode skips hostname check, target VARS, and compose setup entirely.

### Writing a new command

```bash
#!/bin/bash
# DESC: Short description (second line; parsed by the help system)
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
# ... implementation ...
```

No DESC line → listed without description. Place at `commands/<name>.sh` or `commands/<subdir>/<name>.sh`; target overrides at `targets/<t>/commands/...`. Useful helpers in `lib/`: `retry <tries> <delay> <cmd-string>`, `_confirm`, `get_sudo_cmd` (prefers `run0` non-interactively, `sudo` interactively — secureblue), `wait_for_k3s_cluster`, `wait_for_crds <secs> <crd...>`, `get_node_ip`.

## Variables & templating

- **Two-layer vars**: `targets/<t>/VARS.template.sh` (committed, placeholders + generation comments) vs. actual secrets in `secrets/VARS.<t>.sh` (fallbacks in order: `secrets/VARS.sh`, root `VARS.<t>.sh`, root `VARS.sh`). All gitignored. `source_env` hard-fails if the real file is missing any template `export`.
- **Universal VARS** — target-agnostic secrets live in `secrets/VARS.sh` (fallback: root `VARS.sh`), sourced on demand via `source_universal_env()` (lib/env.sh) by universal commands that need them. Not template-validated — each command checks for its own variables and fails with its own error (e.g. `renovate` requires `RENOVATE_GITHUB_TOKEN`).
- **`ENVSUBST_VARS`** — allowlist passed to envsubst: every export in the real VARS file + built-ins (`MY_UID TARGET COMPOSE_STATE_DIR COMPOSE_STATE_BACKUP_DIR K3S_STATE_DIR PVC_BACKUP_DIR INFRA_ROOT DOCKER_GID PROXY_IP USER`) + derived `*_HASHED` vars. Only known vars are expanded; leftovers surface as validate errors.
- **`*_HASHABLE` → `*_HASHED`** — auto-hashed with `openssl passwd -6` at source time (e.g. Authelia OIDC client secrets: plaintext in VARS, hash mounted into Authelia).
- **Multi-line vars** (Authelia user DB, JWKS, frigate config, geoblock subset) — exported with literal indentation; whitespace is significant in the rendered YAML.
- **Structural `$VARIABLE` placeholders** — a bare `$VAR` line at mapping indent is invalid YAML before expansion; `validate` detects this and downgrades the syntax error to a warning.
- `PROXY_IP` is resolved from `$PROXY_HOST` at render time.

### Compose rendering (`lib/compose.sh`)

- `render_compose_yaml()` — envsubst `compose.yaml` (plus optional gitignored `compose.private.yaml`) → `docker compose config` merge → `$COMPOSE_STATE_DIR/compose.yaml`.
- `configure_compose_templates()` — walks `compose/templates/` → `$COMPOSE_STATE_DIR/`; each component's `prep.sh` runs once before its files render. Suffix handling: `.secret` → envsubst + `chmod 600` (suffix stripped; rendered unconditionally every run), `.plain` → copied verbatim, everything else → envsubst. When root, rendered secrets are chowned to `$MY_UID`.
- `compose install` — renders everything, creates host bind dirs (parent dir only if the path has a file extension) with `$MY_UID` ownership, then `docker compose -p $TARGET -f ... up -d --remove-orphans`. Project name = target. Reboot survival = per-service `restart:` policies (no systemd wrapper).
- `compose backup-state` — local: tars `$COMPOSE_STATE_DIR` via an Alpine container (skips FIFOs/sockets). Remote: `compose backup-state <[user@]host:path> <remote_target>` SSHes into another Infra instance which streams the tar back (`INFRA_BACKUP_STREAM=true` → stdout). Prunes to `$BACKUP_RETENTION` (default 1).
- `compose generate-mtls-certs <server-target>` — per-pair CA, server cert (CN = server target), client cert, plus a preboot client cert when `MTLS_PREBOOT_CLIENT_CERT` is in the client's template. Prints copy-paste blocks for both VARS files; never edits VARS.

## K3s conventions

Component = `targets/<t>/k3s/<name>/`:
- `kustomization.yaml` — required. Filenames by convention: `prereqs.yaml` (secrets/configmaps), `ingress.yaml` (Traefik), `network-policy.yaml`, `helmchart.yaml`.
- Optional hooks: `prep.sh` (before apply), `post.sh` (after apply; typically `wait_for_crds`/`retry` waits), `delete.sh` (custom cleanup before standard deletion).

**Apply pipeline** (`commands/k3s/deploy.sh`) — component files are staged into a temp dir, **envsubst runs on each YAML before kustomize** (so bare `$VAR` refs, including multi-line vars, work in any file), then `kubectl kustomize`, then a sed re-quotes numeric `env[].value`s, then split apply: ConfigMaps/Secrets with `binaryData` (e.g. the WASM plugin ConfigMap) go `kubectl apply --server-side` (client-side's `last-applied-configuration` annotation overflows the 256KiB limit); everything else client-side.

Modes: `apply` (prep → build → apply → post), `delete` (delete.sh → HelmCharts → non-PVC resources → PVCs → patch Released PVs to drop `claimRef.uid`), `diff`, `yaml` (print rendered YAML).

**Authelia header gate (srv0)** — `deploy apply` sets `AUTHELIA_HEADER_GATE_ENABLED="true"` for the run when the `authelia` Service is absent from `base` (first bootstrap). The local WASM plugin `authelia-header-gate` (TinyGo, loaded via `--experimental.localplugins`, shipped in the `traefik-local-plugins` ConfigMap) then returns 401 for any request lacking a `Remote-User` header; its `blocking` field comes from the VARS value. Once Authelia exists, re-applies use the VARS value (default `"false"` → pass-through). Publicly-bypass services use the `authelia-with-optional-header-gate` chain (Authelia bypass + gate). vps0 doesn't use the gate.

**Groups** — `k3s/groups.yaml` lists ordered components. Apply in order, delete in reverse; deleting `base` refuses while any Bound PVCs exist.

**Node commands**
- `setup` — downloads the K3s installer and verifies its SHA256 against GitHub's `main` install.sh; writes config drop-ins (`selinux: true`, `flannel-backend: wireguard-native`, `node-ip`, `flannel-iface-regex`, labels `hostpath-main=true`, `hostpath-extra-storage=true`, `external-exposed=true`, `cluster-init`) plus the containerd CDI drop-in (`config-v3.toml.d/enable-cdi.toml` — enables CDI so the `cdi-specs` component can grant host devices; `join` writes it on agents too); creates the `kubectl` group (with a secureblue `/usr/lib/group` workaround); labels the node for Longhorn default disk + `has-homeassistant-hardware`; configures firewall (firewalld/ufw; K3s ports incl. 51820–21/udp for flannel-wg) and sysctls (inotify, user namespaces). Warns that K3s needs a fixed IP.
- `join <ip> <user> [agent|server]` — from the control plane; **requires an interactive terminal** (refuses non-tty). rsyncs `lib/` to the client, runs the installer over ssh, then interactively asks: AMD GPU label, `scheduling-discouraged` taint, Longhorn replicas (yes → label + auto-increment `default-replica-count`; no → `create-default-disk=false`).
- `update-node-ip` — sed-replaces `node-ip` in drop-ins, adds `50-node-ip.yaml`; **updates etcd member peer URLs before restarting k3s** (k3s is `Type=notify`; a synchronous restart deadlocks), restarts with `--no-block`, patches the node's flannel public-ip annotation + status addresses, re-applies the `namespaces` component. Installs etcdctl on demand.

**system-upgrade** — system-upgrade-controller manifests are always applied from GitHub latest in `prep.sh`; `server-plan`/`agent-plan` versions are Renovate-managed (`vX.Y.Z+k3sN`). After a bump: `k3s deploy system-upgrade apply`, then `kubectl -n system-upgrade get plans,jobs`.

## Storage & PVC backups

- **Longhorn** is the default StorageClass and primary backend (replica count 1, best-effort locality, 2000% over-provisioning; chart version has `# PRESERVE_FULL` — sequential minor upgrades required). NFS (`nfs-server` + `csi-driver-nfs`) and static hostPath PV/PVC pairs (`host-volumes`, RWX, bound to `hostpath-main`/`hostpath-extra-storage` nodes) remain for shared host data.
- **Backup** — `pvc-backup` (base group) is a nightly 3AM CronJob that runs `commands/k3s/backup-pvc.sh --all -y` in-cluster (bitnami/kubectl:latest, hostPath mounts of `$INFRA_ROOT` + `$PVC_BACKUP_DIR`, nodeSelector `hostpath-main`). PVCs labelled `auto-backup: "true"` are archived; annotation `backup.infra/exclude` adds tar `--exclude` patterns. A temp pod (scheduled on the volume's node for RWO; tolerates `scheduling-discouraged`) tars the live PVC (no scale-down) to the shared `pvc-backup-dest` PVC — a static PV bound to the ROOT of the NFS backups share (= `$PVC_BACKUP_DIR`), so archives land directly at their final human-named path `<name>.tar.gz` (with `__backup_timestamp.txt` inside), overwritten each run, reachable from any node.
- **Restore** — scales down all workloads using the PVC (Deployments/StatefulSets only; replica counts recorded), waits for pods, restores via a privileged temp pod, scales back up. `--all` does a bulk scale-down of everything first.
- Both backup and restore pods set **pod-level** `seLinuxOptions.level: s0` (see SELinux below).

## Networking

- **Traefik on srv0** — dual entrypoints: `websecure:443` (LAN, no proxy protocol) and `websecure-proxy:8443` (PROXY protocol v2, trustedIPs `127.0.0.1/32` + pod/service CIDRs — Klipper SNAT makes all traffic appear from those). Public routes listen on both; LAN-only (`*.home.local`) routes only on `websecure`. Middlewares: `geoblock` (allowlist plugin, self-hosted MaxMind GeoLite2 via the `geoip` component's `geoip-service`), `crowdsec-bouncer` (stream mode + AppSec on `:7422`), `forwardauth-authelia` (+ `-basic`), `lan-whitelist` (RFC1918), `cluster-only` (10.42/16), `basicauth-cluster`, `local-no-store`. HTTP → HTTPS redirect. readTimeout=0 on both secure entrypoints (streaming). Plugins are pinned in `additionalArguments` (regex-managed via `github-releases`).
- **vps0 edge** — one Traefik routes by Host/SNI: vps0-local services via Docker labels (two zones, see Targets); `home.$SERVICES_DOMAIN` + wildcard goes through the file provider (`dynamic-configuration.yaml`) to `frps:8080` (HTTP) / `frps:8443` with `tls.passthrough` — vps0 never terminates srv0's TLS; cert-manager on srv0 owns the LE lifecycle. On srv0, cert-manager also runs a local chain (self-signed → `k3s-local-ca` → `ca-issuer`) for `*.home.local`/MQTT TLS; its `post.sh` waits for each chain step before proceeding (race-condition guard).
- **FRP** — frps on vps0 (ports: 7000 control, 8887 preboot SSH, 8888 SSH; healthcheck on admin API :7500). frpc sidecar on srv0 (host network, `pgrep` healthcheck) proxies: ssh→8888, http→8080, https→8443 (local), qbittorrent peer 56881 tcp+udp. Mutual TLS with a per-pair CA (`generate-mtls-certs`); preboot frpc uses a separate client cert.
- **WireGuard** (`wireguard` command) — installs tools, deploys `/etc/wireguard/wg0.conf` (chmod 600), rewrites `AllowedIPs` to `0.0.0.0/1, 128.0.0.0/1` (split-tunnel: less specific than LAN routes, so K3s subnets and LAN stay direct), adds PostUp/PreDown `/32` routes for the endpoint via the physical gateway (dead-loop fix), removes `Table=auto`, and installs a systemd drop-in (`Restart=on-failure`, `RestartSec=15`, `ExecStartPre` deletes stale wg0).
- **LUKS preboot** — `compose install-preboot` (target override): `lib/check_root_luks.sh` detects LUKS via `lsblk -s`; if present, clones `ImranR98/dracut-remote-luks-unlock` and installs a dracut module. srv0 variant: initramfs frpc tunnels SSH via FRPS on port 8887. bigpc variant: crypt-ssh only, dropbear patched to the same port for direct LAN unlock (ethernet only). After rotating preboot mTLS certs, re-run `install-preboot`. When adding initramfs networking, verify with `lsinitrd` that firmware actually made it in (drivers don't retry firmware loads after pivot_root).

## Security

- Secrets never touch git (`/secrets/`, `/VARS*.sh`, `compose.private.yaml` gitignored); `.secret` → chmod 600; Authelia SSO (forward-auth + basic-auth, 2FA); CrowdSec (srv0: Helm chart, agent/LAPI/AppSec + per-service postoverflow whitelists; vps0: single container, bouncer key auto-registered from `BOUNCER_KEY_TRAEFIK`); geoblock allowlist (CA/CN/CU); per-component NetworkPolicies plus baselines in the `namespaces` component (kube-system policy explicitly allows 80/443/8000/8443 to Traefik).
- Docker socket via `wollomatic/socket-proxy`: `dockerproxy` (read-only, Traefik/monitoring); `dockerproxy_priv` (read-write, watchtower) exists only on pc/bigpc — `cap_drop: ALL`, `read_only: true`, `mem_limit: 512M`, user `65534:$DOCKER_GID`.
- Known tradeoff: K3s `HelmChart` `valuesContent` (incl. DB passwords, JWKS, OIDC secrets) is readable by anyone with `get` on `helmcharts.helm.cattle.io` — fine for single-user, audit before granting namespace access.
- **SELinux (Fedora/secureblue nodes)** — Kubernetes assigns per-pod MCS categories; files carry their creator's categories forever. Pods sharing a hostPath tree (syncthing/mdscl/dscpln) and backup/restore pods must set **pod-level** `seLinuxOptions.level: s0` (container-level is ignored). `privileged: true` bypasses enforcement but new files are still labelled. Python/Node `io_uring` denials are audit spam with epoll fallback — fix with `PYTHON_IO_URING=0` / `UV_USE_IO_URING=0` rather than SELinux changes. `setroubleshootd` CPU pegged = denial backlog; fix the denials, don't mask.

### Accepted Security Tradeoffs

Accepted tradeoffs and resolved audit findings — do not re-flag without reading the referenced reasoning:

- **`adminadmin` qBittorrent password is accepted** (`targets/srv0/k3s/qbittorrent/post.sh`) — the web UI sits behind forwardauth-authelia + geoblock + crowdsec; the password is an internal convenience, not a security boundary. Never propose "fixing" it.
- **`.cookies.json` live session cookies are accepted** (`targets/srv0/commands/k3s/test/`) — `.gitignore:14` (`.cookies.json`, no slash) matches at any depth; that is the whole protection. Do not move the file or add hooks.
- **NetworkPolicies ARE enforced** — K3s ships an embedded network-policy controller (kube-router) enabled by default; this repo never sets `--disable-network-policy` (`lib/k3s.sh` sets `flannel-backend: wireguard-native` only). Flannel being the data path does NOT mean policies are unenforced. Verify with `kubectl -n kube-system get pods | grep -i router` before claiming otherwise.
- **The authelia-header-gate is NOT forgeable** — in the `authelia-with-optional-header-gate` chain (`targets/srv0/k3s/traefik/middlewares.yaml`), `forwardauth-authelia` runs FIRST and, on any 2xx auth response, deletes client-supplied `Remote-User` and re-adds it only if Authelia's verify response contained it (Traefik v3 `pkg/middlewares/auth/forward.go`). `bypass` responses carry no `Remote-User`, so a forged header is stripped → the gate 401s. When Authelia is unreachable, forwardauth aborts the chain (500) before the gate runs. The only way `Remote-User` reaches the gate is genuine Authelia authentication. Do not re-flag the gate without reading the chain order.
- **SSH hardening is out of repo scope** — sshd/fail2ban hardening is done manually on the machines, pre-repo. Don't propose `harden-ssh`-style commands. The open SSH tunnel at vps0:8888 is mitigated by pubkey-only auth set up out-of-band.
- **Unpinned supply-chain fetches are accepted tradeoffs** — the dracut clone in `compose install-preboot`, etcdctl "latest" download in `update-node-ip`, `releases/latest` system-upgrade manifests, and the TOFU K3s installer hash check are all deliberate: pinning them costs manual version bumps. Do not propose pinning.
- **vps0 `s01-whitelist` subnet regex stays** (`targets/vps0/compose/templates/crowdsec/postoverflows/s01-whitelist/internal.yaml`) — uptime-kuma needs the exemption and its container IP isn't fixed; there is no better mechanism.
- **Authelia is deliberately NOT behind geoblock** (operator travels outside the CA/CN/CU allowlist). Crowdsec on the srv0 `auth` route is fine; geoblock is not.
- **Public-by-design services**: seerr (geoblock only, no SSO — deliberately shareable), cct26 on vps0 (fully open, no geoblock — deliberate), owncast RTMP ingest :1935 (relies on a strong stream key set in the Owncast admin UI, can't be Traefik-gated).
- **Public hosts deliberately without SSO and/or geoblock** — srv0: `gpt` (Open WebUI), `fmd`, and `rss` (FreshRSS) are public with geoblock + crowdsec only (their own app auth, no Authelia); `tv` (Jellyfin) has crowdsec + `authelia-with-optional-header-gate` + ratelimit but no geoblock. vps0: `plausible` (crowdsec only) and `ytdl` (metube; crowdsec + Authelia `one_factor`) have no geoblock. All deliberate — don't propose adding SSO or geoblock to any of these.
- **Home Assistant gets the ConBee II via CDI, not `privileged`** (`targets/srv0/k3s/cdi-specs/` + `homeassistant/helmchart.yaml`) — the device cgroup blocks unprivileged opens of `/dev/ttyACM0`, so HA requests the `infra.local/devices-conbee` resource. The `cdi-specs` component runs cluster-wide: each node generates its own CDI spec in `/etc/cdi` from its actual `/dev` (grants follow the hardware, not a node label), and the `cdi-device-plugin` DaemonSet registers them. HA still needs pod-level `seLinuxOptions.type: spc_t` (SELinux denies `container_t` the mounted `/run/dbus/system_bus_socket` — Bluetooth integration → host bluez — and the device; verified empirically) plus `capabilities.add: [NET_ADMIN, NET_RAW]` (habluetooth manages the host adapter via direct HCI sockets). Device cgroup access is scoped to the ConBee II alone. Don't propose re-adding privileged.
- **Jellyfin gets /dev/dri via CDI, not `privileged`** (`targets/srv0/k3s/jellyfin/helmchart.yaml`) — requests `infra.local/devices-dri`, runs `container_t` as `$MY_UID`, no spc_t needed (renderD128 is 0666 + container_t-accessible). Device cgroup scoped to the render node. frigate/immich get the same grant (spc_t + s0, pinned to srv0); promtail and the CDI plugin run spc_t instead of privileged; pvc-backup/restore pods are non-privileged (spc_t + DAC_OVERRIDE/FOWNER); ollama uses the `infra.local/devices-amd` grant (kfd + dri, bigpc) with spc_t + s0.
- **nfs-server stays `privileged`** (`targets/srv0/k3s/nfs-server/deployment.yaml`) — it runs a kernel NFS server (`nfsd`/`rpc.mountd`) in-container, which genuinely requires privileged. Internal base component, no ingress; don't propose de-privileging it.
- **vps0 Authelia `one_factor` rules are intentional** for ytdl/ikom/sale (family/guests); only the admin catch-all rule is `two_factor` (TOTP is Authelia's default second factor — no `default_second_factor_policy` needed).
- **srv0 PROXY-protocol trustedIPs include pod/service CIDRs on purpose** (`targets/srv0/k3s/traefik/traefik.yaml`) — frpc connects to `127.0.0.1:8443`, but the port is served by a klipper-lb `svclb` pod (host network) which forwards to the Traefik Service; kube-proxy SNAT makes the Traefik pod see pod/service-CIDR sources, and the PROXY v2 header (emitted by vps0's Traefik `serversTransport frps-proxy`, `dynamic-configuration.yaml`) rides inside the tunnel stream. Untrusted sources would leave the header unparsed and corrupt the TLS stream — narrowing below these CIDRs breaks `home.*`. Consequence accepted: any pod can spoof a PROXY header to the host port.
- **CrowdSec bouncer `clientTrustedIPs` is a client bypass-whitelist, not an XFF/proxy setting** (per the plugin README: "List of client IPs to trust, they will bypass any check from the bouncer or cache"). XFF trust is `forwardedHeadersTrustedIPs` (both stacks: `127.0.0.1/32` only). vps0 removed its `clientTrustedIPs: 172.19.0.0/24` — docker-network callers are exempted from decisions at the crowdsec layer via the `s01-whitelist` postoverflow instead. Don't reintroduce `clientTrustedIPs` to "fix" internal traffic.
- **Agents must never read `secrets/` or any VARS file** — secrets are private by design; audits check gitignore coverage and git history, not file contents.

## Updates (Renovate)

Renovate runs **automatically every day at 17:00 America/Toronto** as the `renovate` K3s CronJob on srv0 (base group, `targets/srv0/k3s/renovate/`) — the full `renovate/renovate` image (ships the Go toolchain, so the gomod manager works). The pod mounts only two files of the syncthing-synced repo (`secrets/VARS.sh` and `.git/config`, read-only) to source `RENOVATE_GITHUB_TOKEN` (auto-rotates on sync) and to infer `RENOVATE_GIT_AUTHOR`; Renovate itself clones from GitHub. `./infra.sh renovate [--dry-run]` (`commands/renovate.sh`) is the manual/on-demand equivalent for other machines (needs Node/npm and `go` from prereqs for gomod updates; runs on the machine you're on, opening PRs directly on GitHub).

Review/apply flow (manual only for critical infra; automerge for everything else per scope below): fetch the PR branch (`git fetch origin pull/<n>/head:renovate/pr-<n>`, then `git checkout renovate/pr-<n>`), `./infra.sh <target> validate`, then merge locally and `git push origin master`. Merges never happen in the platform UI — origin stays the source of truth. Renovate rebases its open PRs and auto-closes them once the change lands on `master` (next run).

**Automerge scope** — Renovate auto-merges anything *not* matching the critical-infra exclusion (packageRules `matchFileNames` + `matchUpdateTypes`). For critical infra — srv0 K3s base group (namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring), vps0 compose (public edge), and the srv0 frpc tunnel compose — only **major** updates stay manual; minor/patch automerges normally. Longhorn exception: patches automerge, but **minor** bumps are proposed without automerge (sequential minor upgrades are mandatory — never merge a minor skip). The grouped docker-digests PR is always manual (it mixes base images). Everything else — apps-namespace k3s components, pc/bigpc/rpi compose, unmanaged arr-stack dirs — automerges including majors (no CI gate; a merged change only deploys when you next run `compose install`/`k3s group apply`).

**Watchtower vs Renovate ownership** — watchtower runs only on pc/bigpc and updates every local container *without* the `com.centurylinklabs.watchtower.enable=false` label — in practice just compose `syncthing/syncthing` (kept untagged; socket-proxy is labeled false). Renovate ignores `syncthing/syncthing` under the docker-compose manager only, so the srv0 K3s syncthing (pinned tag) stays Renovate-managed. Everything else is Renovate's (srv0/vps0/rpi have no watchtower at all). Watchtower's own image is digest-pinned by Renovate (`nickfedor/watchtower:latest`) since watchtower never self-updates.

`renovate.json` at root (repository config): built-in **kubernetes** manager (`managerFilePatterns: /^targets\/.*\.ya?ml$/` — plain pod-spec images) and **docker-compose** manager (all compose images) plus four regex managers for formats nobody parses natively: (1) images inside HelmChart `valuesContent` blocks (fileMatch `*helmchart*.ya?ml$` — hence HelmChart files are named `*helmchart.yaml`), (2) HelmChart CR versions (`oci://` resolved via the docker datasource — the helm datasource has no OCI support — or `chart:`+`repo:`+`version:`), (3) K3s plan versions (`github-releases` on `k3s-io/k3s`, custom versioning), (4) Traefik plugin pins in `additionalArguments` (`github-releases`). Global options (token, repo) are set by the runner script, not the repo config. packageRules: pin floating `latest|stable|release|alpine` tags (and every untagged compose image, which carries an explicit `:latest`) to digests and group all digest pins/refreshes into one PR (prHourlyLimit 20); block majors for `postgres`, `clickhouse/clickhouse-server`, `fedora` (the old `# PRESERVE_MAJOR` semantics — Renovate can't read inline comments, so they're package-level rules); disable syncthing (compose; watchtower-owned on pc/bigpc) and the frozen moving-sale site image. Longhorn minor PRs are never automerged (sequential minor upgrades required); immich's postgres image gets custom regex versioning (same-shape `18-vectorchordX.Y.Z-pgvectorA.B.C` tags only, postgres major locked via the compatibility group) — the only deliberately unmanaged files are none; the WASM plugin's go.mod is gomod-managed via the CronJob's Go toolchain. No other annotations — Renovate's default update decision applies everywhere.

Compose image ownership:
| Where | Updater |
|---|---|
| srv0 (frpc), pc/bigpc compose | Renovate PRs; watchtower (pc/bigpc) auto-updates only compose syncthing |
| vps0 compose (pinned or digest-pinned) | Renovate PRs (no watchtower on vps0) |
| Floating/untagged k3s + compose images | Renovate digest-pin PRs (tag stays, digest refreshed) |

Post-update: `git diff` → `./infra.sh <target> validate` → deploy.

## Resource sizing tiers (never ad-hoc)

| Tier | K8s limits/requests | Compose mem_limit |
|---|---|---|
| small | 512Mi / 128Mi | 512M |
| medium | 2Gi / 128Mi | 2G |
| large | 8Gi / 2Gi | 8G |

| Storage tier | PVC size |
|---|---|
| small | 5Gi |
| medium | 50Gi |
| large | 200Gi |
| 4Ti | 4096Gi |

## Directory layout

```
infra.sh                        # CLI entry point
commands/                       # Global command implementations
commands/renovate.sh            # Universal: run Renovate (opens PRs on GitHub)
commands/_internal/             # _patch_node_ip.py
lib/                            # common.sh (index) → pkg/env/net/k3s/compose/validate/pvc/mtls-certs
lib/plugins/authelia-header-gate/   # WASM plugin source + build
secrets/                        # VARS.<target>.sh + VARS.sh (gitignored)
targets/<target>/
  VARS.template.sh
  compose/compose.yaml          # $VARIABLE placeholders
  compose/compose.private.yaml  # Optional gitignored overlay, merged over compose.yaml
  compose/templates/            # .secret/.plain render pipeline + per-component prep.sh
  k3s/<component>/              # kustomization.yaml + YAML + optional hooks
  k3s/groups.yaml
  commands/                     # Target-specific overrides
current_target/compose_live_state/   # Rendered state (gitignored, ephemeral)
compose_state_backups/ k3s_state_backups/   # Backup archives (gitignored)
architecture.svg|.excalidraw        # Architecture diagram
```

## Environment variables (always available)

`$INFRA_ROOT` (repo root), `$TARGET`, `$COMPOSE_STATE_DIR` (`current_target/compose_live_state`), `$COMPOSE_STATE_BACKUP_DIR` (`compose_state_backups`), `$K3S_STATE_DIR` (`current_target/k3s_live_state`), `$PVC_BACKUP_DIR` (`k3s_state_backups`), `$MY_UID` (current UID, forced 1000 when root), `$DOCKER_GID`, `$PROXY_IP` (resolved from `$PROXY_HOST`), `$ENVSUBST_VARS`.

## Rules

- **Always apply changes through `./infra.sh`** — never raw `docker compose`/`kubectl` for mutations. Direct inspection (logs, get, describe, curl) is fine.
- **Docker needs no manual sudo** — `lib/common.sh` defines a `docker()` wrapper that transparently retries with sudo/run0 when the docker socket is permission-denied (user not in the docker group on srv0/pc/bigpc), prompting for elevation instead of failing. Only daemon-permission errors trigger it; real CLI/daemon-down errors pass through.
- Never edit files under `current_target/` (rendered output).
- Never commit secrets (VARS files, `.cookies.json`, `compose.private.yaml` are gitignored).
- New components must follow the sizing tiers and include NetworkPolicies.
