# AGENTS.md

Infra is an IaC repo for a multi-machine homelab. The user interacts with the cluster directly through the real tools — `helm`, `kubectl`, and `docker compose` — plus a small set of bash scripts for the steps no real tool covers (config validation, node provisioning, preboot, WireGuard, backups). Everything for a target lives in `targets/<t>/`; shared scripts sit in `scripts/`, secrets in the gitignored `config/`. No build step, no wrapper CLI: the target is **always explicit** — target-selecting scripts (`validate`, `compose-backup`) take it as their first argument, and nothing derives it from the machine's hostname. Ops divide into target-selecting ops (validate, compose-backup — they name a target) and machine-local ops (prereqs, renovate, preboot, wireguard, k3s provisioning — they act on the machine they run on and take no target). k3s applies go through plain Helm against the two srv0 charts (base + apps); compose consumes secrets natively (dotenv via `--env-file`, real files for certs); k3s node provisioning goes through the repo's own bash scripts wrapping the official get.k3s.io installer. Audience assumed to know Docker/Compose, Kubernetes, Traefik, bash.

## Prerequisites

Bash 4+, Python 3, Docker Compose v2, kubectl (K3s targets), helm (srv0), yq, jq, curl, openssl. Node.js/npm and `go` for local `renovate` runs (npx + gomod manager). Dev-only: `shellcheck`, `yamllint`. Install everything: `bash scripts/prereqs.sh` on the machine to prepare — it installs the packages, the pinned helm binary, the official Docker bootstrap, generates the machine-fact `.env` for the local compose target, creates the host bind dirs, and seeds `acme.json`. Re-run it after repo changes that add compose bind dirs (idempotent).

## Targets

`targets/` is authoritative — the list below is current but may drift.

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + frpc Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, FRP server (frps), web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm) via agent node; syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

Each target dir: `config_template/` (committed; documents every required variable + generation commands — copy to `config/<t>/`), optional `compose/` and/or `k3s/`.
Notable per-target facts:
- **srv0** — `base` group: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring, cdi-specs. `apps`: immich, logtfy, jellyfin, navidrome, mdscl, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, dscpln, opencanary, flaresolverr, fmd, plik, syncthing, headlamp, frigate (see `k3s-base/templates/` + `k3s-apps/templates/`). Compose sidecar = frpc only. Ollama runs on the `bigpc` agent (RX 9070/ROCm); Open WebUI reaches it in-cluster only (no LAN exposure). Jellyfin/Immich ML/Frigate use srv0's Iris Xe iGPU; Frigate recordings stay on NFS deliberately so the pod can move nodes. Home Assistant integration auto-installs on every pod start (no HACS).
- **bigpc** — K3s agent labelled `has-amdgpu=true`, tainted `scheduling-discouraged` (PreferNoSchedule), no Longhorn replicas (`create-default-disk=false`); Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host net).
- **vps0** — Compose: frps, traefik, authelia + db, crowdsec, plausible (app/ClickHouse/Postgres/state-fixperms), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, cct26, moving-sale, obtainium, socket proxies. No watchtower — all vps0 images are Renovate-owned (floating tags digest-pinned). Two domain zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`).
- **rpi** — go2rtc runs the official image untouched; a one-shot `go2rtc-init` service generates the stream password on first start and persists it in `current_target/compose_live_state/go2rtc/` (`password` file + `go2rtc.env` consumed via compose `env_file`); WebUI loopback-only. `scripts/prereqs.sh` on rpi is just the one-time machine bootstrap (Docker install + the go2rtc state bind dir owned by `$MY_UID`) — rpi has no `config_template/` and no machine-fact needs.

## Essential commands

```
# everyday ops (scripts/ is reachable from anywhere — each script resolves the
# repo root itself; the deploy commands themselves are plain helm/docker compose):
bash scripts/validate.sh srv0                        # config completeness/placeholders + helm lint/template
bash scripts/validate.sh vps0                        # compose.env + file completeness/placeholder check

# k3s (srv0) — plain helm, no wrapper; run validate.sh first as the preflight:
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
helm uninstall srv0-apps -n apps                     # delete: apps first, then srv0-base (PVCs retained)

# compose — run ON the target machine, from the repo root:
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  up -d --remove-orphans
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  down <svc>   # then `up -d <svc>` to restart one service
docker compose --env-file config/srv0/compose.env --env-file targets/srv0/compose/.env \
  -f targets/srv0/compose/compose.yaml up -d   # frpc sidecar
# pc/bigpc/rpi: docker compose -f targets/<t>/compose/compose.yaml up -d
#   (no --env-file — the project-dir machine-fact .env auto-loads)

bash scripts/compose-backup.sh vps0                  # tar the compose state ([-e backup_remote=user@host:path])
bash scripts/pvc.sh backup --all -y                   # PVC backup (or: pvc.sh backup <name>)
bash scripts/pvc.sh restore --all -y                  # PVC restore (or: pvc.sh restore <name>)
sudo bash scripts/update-node-ip.sh [--ip X] [--force]   # K3s node IP change

# machine-local (act on the machine they run on, take no target):
bash scripts/prereqs.sh
bash scripts/renovate.sh [--dry-run]                 # manual Renovate run (opens PRs on GitHub)
bash scripts/preboot.sh frpc|crypt-ssh               # initramfs LUKS unlock
bash scripts/wireguard.sh <path/to/wg0.conf>
bash scripts/k3s-server.sh                           # bootstrap THIS machine as the control plane
bash scripts/k3s-join.sh <node_ip> <node_user> \
  [--role agent|server] [--amdgpu auto|yes|no] \
  [--scheduling-discouraged] [--longhorn-replicas]   # run ON the control plane

# dev-only:
shellcheck $(find scripts targets -name '*.sh' -not -path '*/plugins/*')
yamllint -c .yamllint targets/*/config_template \
  targets/srv0/k3s-base/values.yaml targets/srv0/k3s-base/Chart.yaml targets/srv0/k3s-base/files \
  targets/srv0/k3s-apps/values.yaml targets/srv0/k3s-apps/Chart.yaml
```

The retained scripts warn (or hard-fail, via `require_target_host`) on hostname/target mismatches. Non-interactive PVC confirmations: pass `-y` to the script.

Ad-hoc diagnostics (no dedicated commands; run on the srv0 control plane):
- Mount a PVC + hostPath in a throwaway pod and shell into it:
  `kubectl run pvc-shell --rm -it --restart=Never -n <ns> --image=ubuntu:24.04 --overrides='{"spec":{"containers":[{"name":"s","image":"ubuntu:24.04","stdin":true,"tty":true,"command":["bash"],"volumeMounts":[{"name":"pvc","mountPath":"/pvc"},{"name":"host","mountPath":"/host"}]}],"volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"<pvc>"}},{"name":"host","hostPath":{"path":"/tmp/pvc-transfer"}}]}}'`
- NFS write/read smoke test against the shared RWX backup PVC (`pvc-backup-dest` in `base`):
  `kubectl run storage-test --rm -i --restart=Never -n base --image=busybox:1.36 --overrides='{"spec":{"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c","echo ok > /mnt/t && cat /mnt/t && rm /mnt/t"],"volumeMounts":[{"name":"d","mountPath":"/mnt"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"pvc-backup-dest"}}]}}'`

## Dispatch system

**Real tools are the CLI** — `helm`, `kubectl`, `docker compose` — fronted by no wrapper. `scripts/` holds only the steps that have no real-tool equivalent. Target-selecting scripts take `<target>` as their first argument (never inferred from the hostname); machine-local scripts act on the machine they run on and take none.

All ops logic lives in `scripts/` (k3s-generic too — `pvc.sh` and `update-node-ip.sh` are cluster-generic and moved there from the target dir); nothing is Ansible-style inventory. Scripts must run **as a file** in two places: the in-cluster `pvc-backup` CronJob runs `scripts/pvc.sh backup --all -y` from a kubectl pod (the pod mounts `$INFRA_ROOT` hostPath — the whole repo is reachable), and the node-IP update stays bash (`scripts/update-node-ip.sh` — the etcdctl dance is not worth porting anywhere). `scripts/renovate.sh` is the manual runner for Renovate (the in-cluster renovate CronJob inlines the same steps).

### Script inventory

| Script | Selects | Acts on | Notes |
|---|---|---|---|
| `scripts/validate.sh <t>` | target | read-only, any machine | config_template→config completeness/placeholders + helm lint + both-chart template render (srv0); compose `../../../config/` mount check. Prints variable names only. |
| `scripts/compose-backup.sh <t>` | target | ON the target (hostname asserted) | tars the compose state via an Alpine container; `-e backup_remote=user@host:path` streams the tar over SSH |
| `scripts/prereqs.sh` | — | this machine | packages, pinned helm, Docker bootstrap, machine-fact `.env`, host bind dirs, acme seed |
| `scripts/renovate.sh` | — | this machine (opens GitHub PRs) | needs `RENOVATE_GITHUB_TOKEN` in config/VARS.env |
| `scripts/preboot.sh frpc\|crypt-ssh` | — | this machine | initramfs LUKS unlock; frpc certs from `config/<hostname>/frpc/` |
| `scripts/wireguard.sh <conf>` | — | this machine | deploys a provider wg0.conf (split-/1 routes, endpoint dead-loop route) |
| `scripts/k3s-server.sh` | — | this machine (becomes the control plane) | node prep + installer + server config + labels |
| `scripts/k3s-join.sh <ip> <user> [...]` | — | control plane + the joining node | token travels via stdin over ssh; labels/taint/Longhorn after Ready |
| `scripts/k3s-node-prep.sh` | — | the node (root) | sysctls, CDI drop-in, firewall, kubectl group, pciutils — shared by server/join |
| `scripts/pvc.sh` | — | the cluster (or in-cluster pod) | PVC backup/restore |
| `scripts/update-node-ip.sh` | — | the node | K3s node IP change |

### Writing a new script

New target-selecting logic belongs in `scripts/` (shared, generic) or at the target root (`targets/<t>/foo.sh`) when it serves a single target. Machine-local logic (preboot-style, acting on the machine itself) takes no target. Every script follows one convention: `#!/bin/bash`, a `# DESC:` second line, `set -euo pipefail`, a `usage()` function, and the common.sh bootstrap:

```bash
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
```

(The bootstrap self-computes the repo root but honors a pre-set `INFRA_ROOT` — the in-cluster pods ship it in their env and must not get host paths recomputed over them.) Target-selecting scripts call `require_target "$1"` (warns on hostname mismatch — for check flows) or `require_target_host "$1"` (hard-asserts — for ops that mutate the machine). Useful helpers in `scripts/common.sh`: `_confirm`, `get_sudo_cmd`, `get_node_ip`, `wait_for_k3s_cluster`, `set_my_uid`.

### Comment & doc guidelines

- Comments explain current behavior and non-obvious WHYs only — never history ("used to", "previously", "replaces the old X", "deleted"); past designs live in git history.
- Keep comments minimal: file headers say what the file IS; don't restate the code or narrate steps.
- No device names (srv0/vps0/bigpc/pc/rpi) in shared code (`scripts/`) — shared logic must stay generic (e.g. "the frpc preboot reads the certs from config/<hostname>/frpc/", not "from srv0's certs"). Per-device facts live in `targets/<t>/`; README.md and AGENTS.md are the only shared files that may name targets.
- Docs describe the current codebase only — migration guides and historical notes are deleted once the migration lands.
- After editing, scan for this pattern: `grep -rniE 'the old|previously|formerly|replaces the old|is gone' scripts targets` should return nothing but legitimate current-behavior notes.

## Variables & secrets

- **Layout** — every target's secret inputs are templated in `targets/<t>/config_template/` (committed): `values.yaml` (k3s helm values) and/or `compose.env` (compose dotenv) plus any additional files the target needs (mTLS certs, the Authelia users DB). The user copies the folder to `config/<t>/` (`cp -r targets/<t>/config_template config/<t>`) and fills every value — `config/<t>/` mirrors the template structure exactly and is gitignored. Where possible the template files carry comments with the generation command for each value (e.g. `openssl rand -hex 32`); `scripts/validate.sh` rejects any leftover placeholders.
- **srv0 — split by consumer**: `config/srv0/values.yaml` (plain YAML, gitignored) feeds ONLY the k3s charts (`helm upgrade -f`, both `k3s-base` and `k3s-apps`). The compose sidecar (frpc) takes `config/srv0/compose.env` (dotenv: `PROXY_HOST`, `TLS_SERVER_NAME` — passed with `docker compose --env-file`) and the mTLS certs as real 0600 files under `config/srv0/frpc/`. `targets/srv0/config_template/values.yaml` documents every YAML key + the env/cert layout (its FRP section).
- **vps0 — dotenv only**: `config/vps0/compose.env` (gitignored, template `targets/vps0/config_template/compose.env`) is consumed natively by compose via `--env-file` — no conversion step, no render step. Multi-line secrets are NOT dotenv values: the Authelia users DB lives at `config/vps0/authelia/users_database.yml` and the frps certs at `config/vps0/frps/` (0600 files, mounted `:ro`). Machine facts (`MY_UID`/`DOCKER_GID`/`MY_USERNAME`) come from the prereqs-generated `targets/vps0/compose/.env`, passed as a second `--env-file` (later file wins).
- **pc/bigpc/rpi — machine facts only**: no `config_template/` (no secret variables); `scripts/prereqs.sh` writes a gitignored `targets/<t>/compose/.env` with `MY_UID`/`DOCKER_GID`/`MY_USERNAME`. It is generated for **every** target (config envs never carry per-machine facts) — vps0/srv0 pass it as a second `--env-file`, pc/bigpc/rpi get it auto-loaded as the project-dir `.env`.
- **No encryption** — all secret values are plain text at rest (gitignored under `config/`). Create them by copying the template folder and filling every value literally.
- **Format** — values.yaml: map `KEY: value`; multi-line values are literal block scalars (`|`), spliced verbatim by helm (`| indent "N"`); inline comments (` # ...`) work after single-line values; bare `$` and `#` are literal (write `$argon2id$...` unescaped). compose.env: `KEY=value`; single-quote values containing `$` (compose would interpolate them inside double quotes); multi-line values use `\n` escapes; inline comments work after single-line values.
- **Validation** — `scripts/validate.sh <target>` asserts every `config_template/` file has a filled counterpart in `config/<target>/` (same relative path), rejects placeholder values (`change_me`/`changeme`/`abc`/`REPLACE_ME`/`<...>`), checks key completeness for values.yaml/compose.env, verifies compose `../../../config/` mounts exist, and — for srv0 — lints + templates both k3s charts (missing values surface as `<no value>` render failures). Variable names only are printed. Run it before every `helm upgrade --install`.
- **Universal VARS** — target-agnostic secrets live in `config/VARS.env`, dotenv format. Loaded on demand by the commands that need them (`scripts/renovate.sh` requires `RENOVATE_GITHUB_TOKEN`; the in-cluster renovate CronJob does `set -a; . /repo/config/VARS.env`). Not template-validated — each command checks its own variables.
- **mTLS certs** — generated with the documented copy-paste `openssl` commands in the FRP sections of `config_template/values.yaml`/`config_template/compose.env` (per-pair CA, server/client certs, preboot client cert); PEMs live as real files under `config/<t>/frpc/`/`config/vps0/frps/`.
- **`*_HASHED` (k3s authelia)** — precomputed hashes stored in the same YAML next to their `*_HASHABLE` plaintexts (`openssl passwd -6` or `authelia crypto hash generate pbkdf2`; the generation commands are in `config_template/values.yaml`).
- `PROXY_IP` is resolved from `PROXY_HOST` by `scripts/preboot.sh` (`getent hosts`) when generating the initramfs frpc config.

### Compose pipeline

- Compose files: `targets/<t>/compose/compose.yaml` (+ optional gitignored `compose.private.yaml`, merged with `-f`). Interpolation is native docker compose: `$VAR` from `--env-file config/<t>/compose.env` (vps0/srv0) or the auto-loaded project-dir `.env` (pc/bigpc/rpi). Project name = the `name: <t>` attribute in the compose file.
- Inlined configs: every former template (frpc.toml, authelia configuration.yml, the traefik dynamic config, crowdsec notifications/whitelist, logtfy config.json) is a top-level `configs:` block — `content:` with `$VAR` interpolation (or an `environment: VARNAME` source) — granted to services via the `configs:` long syntax with `target:` and `mode:` (0400 for secret-bearing, 0440 otherwise). Verbatim files (frps.toml, crowdsec acquisitions/profiles, auth.py, clickhouse-config.xml, go2rtc.yaml) are committed under `targets/<t>/compose/files/` and mounted `:ro`.
- State: `current_target/compose_live_state/` (gitignored) holds the runtime state only (acme.json, sqlite DBs, upload dirs). Compose files reference it with relative paths (`../../../current_target/compose_live_state/...` — resolved against the compose file's directory). `scripts/prereqs.sh` creates missing bind dirs owned by `$MY_UID` (Docker would create them as root — containers running as `$MY_UID` couldn't write) and seeds `traefik/acme.json` (`{}`, 0600, first run).
- Ownership self-heal — containers that run as a fixed non-`$MY_UID` user (ClickHouse 101, Plausible 999) have a one-shot `state-fixperms` init service (alpine, `cap_drop: ALL` + `CHOWN`/`FOWNER`/`DAC_OVERRIDE`) that chowns their state dirs before the apps start; dependent services gate on it with `condition: service_completed_successfully`. It re-runs after `docker compose down <svc>`, so ownership drift from a host-side chown is fixed by the next deploy.
- Deploy (from the repo root, ON the target machine): `docker compose --env-file config/<t>/compose.env --env-file targets/<t>/compose/.env -f targets/<t>/compose/compose.yaml [-f targets/<t>/compose/compose.private.yaml] up -d --remove-orphans` (pc/bigpc/rpi: `docker compose -f targets/<t>/compose/compose.yaml up -d` — no `--env-file`, the project-dir `.env` auto-loads). Restart one service: `... down <svc>` then `... up -d <svc>` (re-reads config + env). Reboot survival = per-service `restart:` policies (no systemd wrapper).
- Backup: `scripts/compose-backup.sh <t>` — local: tars `current_target/compose_live_state` via an Alpine container (skips FIFOs/sockets) and prunes to `$BACKUP_RETENTION` (default 1). Remote: `-e backup_remote=user@host:path` streams the tar back over SSH into `compose_state_backups/` (the remote runs docker directly — no scripts needed there).
- The compose hostname guard: `scripts/compose-backup.sh` asserts `hostname == target` via `require_target_host`; plain `docker compose` runs are your own guard (deploy from the target's own checkout).

## K3s conventions

Components live in two sibling charts — `targets/srv0/k3s-base/` and `targets/srv0/k3s-apps/` (split so each release is plain `helm upgrade --install` with no scope gates):
- `k3s-base/templates/` + `k3s-apps/templates/` — one file per component, native Helm templates (`{{ .Values.X }}` refs; secrets/config come from `config/srv0/values.yaml`). Secrets/configmaps live in `prereqs` sections of the component files, next to their Traefik `IngressRoute`s and `NetworkPolicy`s. `k3s-base/` also carries `files/` (WASM plugin + traefik-plugin-config), `plugins/` (the plugin source), and `geoip-src/` (the geoip helper image source).
- `k3s-apps/templates/hooks.yaml` — one seeding Job (`immich-seed`) as a Helm `post-install,post-upgrade` hook with `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`; RBAC via the `helm-hooks` ServiceAccount/Role. It skips when the admin already carries an OAuth identity (`immich-admin list-users`, no auth needed); on a fresh DB it creates the admin via the sign-up API and persists the generated password in the `immich-seed-admin` Secret (apps) so later runs authenticate via the API — no interactive `immich-admin` prompts. Other first-boot seeding is declarative: qBittorrent via a `qBittorrent.conf` ConfigMap + copy-once initContainer in `k3s-apps/templates/qbittorrent.yaml`, the GeoLite2 DB via the geoip Deployment's `geoipupdate` initContainer (weekly CronJob keeps it current).

**Apply pipeline** — plain helm commands, no wrapper (`scripts/validate.sh srv0` is the preflight):
```
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
```
Two releases: `srv0-base` (k3s-base chart, namespace base) and `srv0-apps` (k3s-apps chart, namespace apps). Preflights (apply only): the secret values file must exist and contain no placeholders, and the rendered charts must contain no `<no value>` (helm silently renders missing keys) — `scripts/validate.sh srv0` runs all three. Delete: `helm uninstall srv0-apps -n apps` then `srv0-base` (Helm retains PVCs). The charts contain: (a) all repo-owned components as Helm templates (secrets, configmaps, ingresses, PVCs, cronjobs, the traefik Middlewares/HelmChartConfig + WASM plugin ConfigMap via `.Files.Get`), (b) the 19 upstream-app **HelmChart CRs** (11 in base, 8 in apps) — helm-controller still owns the app releases exactly as before (avoids release-name-derived resource naming), (c) vendored system-upgrade-controller manifests + Plans, (d) the immich seeding hook as a `post-install,post-upgrade` Job with scoped RBAC under the `helm-hooks` ServiceAccount.

Ops: `helm list/history/rollback`, `helm get values`, `helm template`, `helm diff upgrade` (helm-diff plugin).

**Authelia header gate (srv0)** — `AUTHELIA_HEADER_GATE_ENABLED` is a VARS knob (default `"false"` → pass-through); on a fresh bootstrap set it `"true"` until Authelia is Ready, then back to `"false"`. The local WASM plugin `authelia-header-gate` (TinyGo, loaded via `--experimental.localplugins`, shipped in the `traefik-local-plugins` ConfigMap) then returns 401 for any request lacking a `Remote-User` header; its `blocking` field comes from the VARS value. Once Authelia exists, re-applies use the VARS value (default `"false"` → pass-through). Publicly-bypass services use the `authelia-with-optional-header-gate` chain (Authelia bypass + gate). vps0 doesn't use the gate.

**Groups** — apply both scopes in order (`base` then `apps`); delete in reverse (`srv0-apps` then `srv0-base`). Helm retains PVCs on uninstall.

**Node commands (bash — `scripts/`)**

Node provisioning is owned by `scripts/k3s-server.sh` and `scripts/k3s-join.sh` (the official `get.k3s.io` installer — no provisioning collection, no inventory anywhere). Cluster policy lives in the scripts themselves:

- `k3s-server.sh` (no args, run ON the node): `k3s-node-prep.sh` (sysctls via `/etc/sysctl.d/90-k3s.conf`, the containerd CDI drop-in `enable-cdi.toml` — enables CDI so the `cdi-specs` component can grant host devices, firewall (firewalld/ufw; K3s ports incl. 51820–21/udp for flannel-wg), the `kubectl` group, pciutils) + the installer + `/etc/rancher/k3s/config.yaml` (`selinux: true`, `write-kubeconfig-mode: "0640"`, `flannel-backend: wireguard-native`, the flannel-iface regex, `cluster-init: true`, `node-ip`, labels `hostpath-main=true`, `hostpath-extra-storage=true`, `external-exposed=true`) + restart + waits for the server token and the API + labels the node (Longhorn default disk, `has-homeassistant-hardware`). K3s needs a fixed IP — if it changes, run `scripts/update-node-ip.sh`.
- `k3s-join.sh <node_ip> <node_user> [...]` (run ON the control plane; prompts for sudo on the control plane and the joining node separately — they may differ): reads the token from `/var/lib/rancher/k3s/server/token`, resolves the server IP, streams `k3s-node-prep.sh` + the installer to the node over SSH with the token appended on stdin (never argv; the token lands in the node's root-only `k3s-agent.service.env` for agents, or in `config.yaml` for joined servers), waits for the node to appear + become Ready, then applies labels/taint/Longhorn replica count. All join options are CLI flags: `--role agent|server`, `--amdgpu auto|yes|no` (lspci-based detection on the node — vendor `1002`, VGA class; drives ROCm/Ollama scheduling via the `has-amdgpu=true` label), `--scheduling-discouraged` (PreferNoSchedule taint), `--longhorn-replicas` (`create-default-disk=true` + auto-increment of `default-replica-count`, guarded by the label's actual change so re-runs don't double-count; without the flag → `create-default-disk=false`). The installer only runs when k3s is missing — re-provision never re-installs, so it can't fight system-upgrade-controller's ownership of versions. SSH host-key checking is left at the default (on) — the first join prompts to accept the fingerprint, same trust model as plain `ssh`.
- `scripts/update-node-ip.sh` (retained bash, run directly on the node): sed-replaces `node-ip` in drop-ins, adds `50-node-ip.yaml`; **updates etcd member peer URLs before restarting k3s** (k3s is `Type=notify`; a synchronous restart deadlocks), restarts with `--no-block`, patches the node's flannel public-ip annotation + status addresses. Installs etcdctl on demand.

**system-upgrade** — system-upgrade-controller manifests are **vendored** in `templates/base/system-upgrade-controller.yaml` (downloaded from `releases/latest` of rancher/system-upgrade-controller at cutover; bump by re-downloading `crd.yaml` + `system-upgrade-controller.yaml` and replacing the template — the controller image inside is Renovate-managed via the kubernetes manager). `server-plan`/`agent-plan` versions are Renovate-managed (`vX.Y.Z+k3sN`, matched in the templates by the plan-version regex manager). After a bump: apply `srv0-base`, then `kubectl -n system-upgrade get plans,jobs`.

**valuesSecrets** (k3s helm-controller) — HelmChart CRs can pull values from a namespaced Secret: `spec.valuesSecrets: [{name, keys}]`; each listed key is projected as a `values-0-00N-HelmChart-ValuesSecret.yaml` file merged after `valuesContent` (plain Helm deep-merge, later file wins; `keys` must be non-empty). Used by frigate + loki (see Security); changes to the Secret re-trigger the chart upgrade (`ignoreUpdates: false` default). The referenced Secret must live in the CR's namespace and not be named `chart-values-<chart>`.

## Helm crash course (as used in this repo)

**Mental model.** Helm is a package manager that turns a *chart* (templates + values) into Kubernetes manifests and tracks the result as a *release*. Helm is **client-only** — nothing runs in the cluster; the `helm` binary (installed by the prereqs script, version-pinned) does everything from wherever you run it. Each install/upgrade stores the full rendered manifest as a revision (in `sh.helm.release.v1.<name>.v<n>` Secrets). `helm upgrade --install` is idempotent: it three-way-merges the new render against the *last stored* manifest and patches only what changed — re-running the same command with no file changes touches nothing and just bumps the revision counter.

**Three layers of "helm" in this repo — do not conflate them:**
1. **Our two charts** (`targets/srv0/k3s-base/` + `targets/srv0/k3s-apps/`) → releases `srv0-base` + `srv0-apps`, applied by plain `helm upgrade --install` (see the Apply pipeline).
2. **k3s's embedded helm-controller** → the 19 `HelmChart` CRs *inside* our charts. Our releases apply the CR objects; the controller then installs/upgrades the app releases (frigate, immich, …). `helm uninstall srv0-*` does NOT touch these; `kubectl delete helmchart` triggers THEIR uninstall.
3. **k3s bootstrap charts** (traefik + traefik-crd in kube-system) — not ours at all; we only customize traefik via the `HelmChartConfig` template.

**Chart layout** (chart roots = `targets/srv0/k3s-base/` and `targets/srv0/k3s-apps/`):
- `Chart.yaml` — name/version only (no dependencies in these charts).
- `values.yaml` — committed defaults; just the machine-independent built-ins (`MY_UID`).
- `templates/` — one file per component, native Helm templates (`{{ .Values.X }}`; multi-line values splice via `| indent "N"`). No scope gates — each chart IS a scope.
- `files/` (k3s-base) — raw files shipped inside the chart, referenced from templates via `.Files.Get "files/<name>"` (**paths are chart-root-relative — the `files/` prefix is mandatory**; omitting it silently renders empty, which is how the WASM plugin broke).
- `templates/hooks.yaml` (k3s-apps) — Helm **hooks**: Jobs annotated `helm.sh/hook: post-install,post-upgrade` run automatically after every install/upgrade, retried via Job backoff, deleted on success (`helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`).

**Everyday commands:**
```
helm ls -A                                # releases + revision + status
helm history srv0-base -n base            # revision log
helm rollback srv0-base <rev> -n base     # instant rollback to an earlier revision
helm get values srv0-base -n base         # effective values
helm status srv0-base -n base
helm template srv0-base targets/srv0/k3s-base -n base -f targets/srv0/k3s-base/values.yaml \
  -f config/srv0/values.yaml              # dry render
helm diff upgrade srv0-base targets/srv0/k3s-base   # preview (helm-diff plugin)
helm uninstall srv0-apps -n apps          # delete a release; PVCs are retained by Helm default
```

**Pitfalls learned the hard way:**
- `helm lint`/`helm template` need the values files (`-f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml` — the same config file feeds both charts) — without them, `.Values.X` is nil and lint fails with 'invalid value; expected string'. Missing keys render as `<no value>` — `scripts/validate.sh` catches that.
- `.Files.Get` paths need the `files/` prefix (see above).
- Literal `{{` in templates is interpreted by helm — the homeassistant CR's embedded Go templates are escaped as `{{ "{{" }}`.
- Subchart resource names derive from `{{ .Release.Name }}` — that's why the app charts stay HelmChart CRs (helm-controller-managed) instead of umbrella dependencies.
- Never `helm install --force` casually — it deletes/recreates resources; one accidental `--force` during the cutover re-released 4 HelmChart CRs.
- `kubectl apply --dry-run=server` on rendered output gives false positives (e.g. the 256KiB `last-applied-configuration` limit that doesn't apply to Helm's merge) — use helm's own `--dry-run=server`.
- Adoption: pre-existing objects must carry `app.kubernetes.io/managed-by: Helm` + `meta.helm.sh/release-name`/`release-namespace` annotations or helm refuses to install over them.
- Helm uninstall ignores live-object annotations entirely — `helm.sh/resource-policy: keep` only works from the *stored* manifest.
- Helm doesn't auto-resolve k3s's kubeconfig the way k3s's kubectl does — set `KUBECONFIG` to `/etc/rancher/k3s/k3s.yaml` yourself.

## Storage & PVC backups

- **Longhorn** is the default StorageClass and primary backend (replica count 1, best-effort locality, 2000% over-provisioning; chart version has `# PRESERVE_FULL` — sequential minor upgrades required). NFS (`nfs-server` + `csi-driver-nfs`) and static hostPath PV/PVC pairs (`host-volumes`, RWX, bound to `hostpath-main`/`hostpath-extra-storage` nodes) remain for shared host data.
- **Backup** — `pvc-backup` (base group) is a nightly 3AM CronJob that runs `scripts/pvc.sh backup --all -y` in-cluster (bitnami/kubectl:latest, hostPath mounts of `$INFRA_ROOT` + `$PVC_BACKUP_DIR`, nodeSelector `hostpath-main`). PVCs labelled `auto-backup: "true"` are archived; annotation `backup.infra/exclude` adds tar `--exclude` patterns. A temp pod (scheduled on the volume's node for RWO; tolerates `scheduling-discouraged`) tars the live PVC (no scale-down) to the shared `pvc-backup-dest` PVC — a static PV bound to the ROOT of the NFS backups share (= `$PVC_BACKUP_DIR`), so archives land directly at their final human-named path `<name>.tar.gz` (with `__backup_timestamp.txt` inside), overwritten each run, reachable from any node.
- **Restore** — scales down all workloads using the PVC (Deployments/StatefulSets only; replica counts recorded), waits for pods, restores via a privileged temp pod, scales back up. `--all` does a bulk scale-down of everything first.
- Both backup and restore pods set **pod-level** `seLinuxOptions.level: s0` (see SELinux below).

## Networking

- **Traefik on srv0** — dual entrypoints: `websecure:443` (LAN, no proxy protocol) and `websecure-proxy:8443` (PROXY protocol v2, trustedIPs `127.0.0.1/32` + pod/service CIDRs — Klipper SNAT makes all traffic appear from those). Public routes listen on both; LAN-only (`*.home.local`) routes only on `websecure`. Middlewares: `geoblock` (allowlist plugin, self-hosted MaxMind GeoLite2 via the `geoip` component's `geoip-service`), `crowdsec-bouncer` (stream mode + AppSec on `:7422`), `forwardauth-authelia`, `lan-whitelist` (RFC1918), `cluster-only` (10.42/16), `basicauth-cluster`, `local-no-store`. HTTP → HTTPS redirect. readTimeout=0 on both secure entrypoints (streaming). Plugins are pinned in `additionalArguments` (regex-managed via `github-releases`).
- **vps0 edge** — one Traefik routes by Host/SNI: vps0-local services via Docker labels (two zones, see Targets); `home.$SERVICES_DOMAIN` + wildcard goes through the file provider (the `traefik_dynamic` compose config) to `frps:8080` (HTTP) / `frps:8443` with `tls.passthrough` — vps0 never terminates srv0's TLS; cert-manager on srv0 owns the LE lifecycle. On srv0, cert-manager also runs a local chain (self-signed → `k3s-local-ca` → `ca-issuer`) for `*.home.local`/MQTT TLS; its `post.sh` waits for each chain step before proceeding (race-condition guard).
- **FRP** — frps on vps0 (ports: 7000 control, 8887 preboot SSH, 8888 SSH; healthcheck on admin API :7500). frpc sidecar on srv0 (host network, `pgrep` healthcheck) proxies: ssh→8888, http→8080, https→8443 (local), qbittorrent peer 56881 tcp+udp. Mutual TLS with a per-pair CA (generated via the documented openssl commands in the FRP sections of the VARS templates; certs live as files under `config/<t>/frpc|frps/`); preboot frpc uses a separate client cert.
- **WireGuard** (`scripts/wireguard.sh`, machine-local) — deploys a provider `wg0.conf`. The script parses the provider conf (PrivateKey/Address/DNS/MTU/PresharedKey/Endpoint — values never echoed), rewrites `AllowedIPs` to `0.0.0.0/1, 128.0.0.0/1` (split-tunnel: less specific than LAN routes, so K3s subnets and LAN stay direct), and adds PostUp/PreDown `/32` routes for the endpoint via the physical gateway (dead-loop fix). It installs `wireguard-tools`, writes the 0600 `/etc/wireguard/wg0.conf`, and enables the `wg-quick@wg0` systemd unit (config changes apply via `wg syncconf`).
- **LUKS preboot** — `scripts/preboot.sh <frpc|crypt-ssh>`, run on the node. srv0 (frpc): reads the mTLS certs from `config/srv0/frpc/` and `PROXY_HOST`/`TLS_SERVER_NAME` from `config/srv0/compose.env`, resolves `PROXY_IP` itself, generates the frpc-preboot config, and installs initramfs frpc tunnelling SSH via FRPS on port 8887. bigpc (crypt-ssh): dropbear patched to preboot_port for direct LAN unlock (ethernet only). After rotating preboot mTLS certs, re-run the script on srv0. When adding initramfs networking, verify with `lsinitrd` that firmware actually made it in (drivers don't retry firmware loads after pivot_root).

## Security

- Secrets never touch git (`/config/`, `compose.private.yaml`, `targets/*/compose/.env` gitignored); `.secret`-style files are 0600 host files; Authelia SSO (forward-auth + basic-auth, 2FA); CrowdSec (srv0: Helm chart, agent/LAPI/AppSec + per-service postoverflow whitelists; vps0: single container, bouncer key auto-registered from `BOUNCER_KEY_TRAEFIK`); geoblock allowlist (CA/CN/CU); per-component NetworkPolicies plus baselines in the `namespaces` component (kube-system policy explicitly allows 80/443/8000/8443 to Traefik).
- Docker socket via `wollomatic/socket-proxy`: `dockerproxy` (read-only, Traefik/monitoring); `dockerproxy_priv` (read-write, watchtower) exists only on pc/bigpc — `cap_drop: ALL`, `read_only: true`, `mem_limit: 512M`, user `65534:$DOCKER_GID`.
- Known tradeoff: K3s `HelmChart` `valuesContent` (incl. DB passwords, JWKS, OIDC secrets) is readable by anyone with `get` on `helmcharts.helm.cattle.io` — fine for single-user, audit before granting namespace access. Reduced where charts support it: authelia (secret `path:` refs), crowdsec (`externalSecret`), grafana (`admin.existingSecret`), headlamp (`oidc.externalSecret`), rustfs (`secret.existingSecret`), immich/nextcloud/plik (plain-YAML `secretKeyRef`). Where the chart has no secret-ref support but the value is plain YAML, the component uses **`spec.valuesSecrets`** (k3s helm-controller): the secret values live in a namespaced Secret (now `targets/srv0/k3s-apps/templates/frigate.yaml` + `k3s-base/templates/monitoring.yaml`, key `values.yaml`) listed in the CR via `valuesSecrets: [{name, keys}]` — the controller projects it as a later `-f` values file, so the merge is plain Helm deep-merge and renders identically. Done this way: **frigate**'s `env` passwords (its `env` key only accepts plain strings — chart limitation) and **loki**'s S3 keys (the 7.x chart's config handling makes `existingSecretForConfig` too risky; the values merge sidesteps the chart). Remaining unavoidable plaintext: authelia's JWKS PEM (`value:` embedded — the chart generates a RANDOM key if the `CryptographicKey` secret isn't inline; verified the hard way). Also: freshrss stays a root container (official image hardcodes apache on :80 and its entrypoint runs as root — de-rooting needs a custom apache config); nextcloud stays a root container too (verified: the official entrypoint writes /etc/apache2 as root even with APACHE_PORT set — uid 33 crashes on `remoteip.conf` removal; the PVC is already www-data-owned so this is purely an entrypoint limitation).
- **SELinux (Fedora nodes)** — Kubernetes assigns per-pod MCS categories; files carry their creator's categories forever. Pods sharing a hostPath tree (syncthing/mdscl/dscpln) and backup/restore pods must set **pod-level** `seLinuxOptions.level: s0` (container-level is ignored). `privileged: true` bypasses enforcement but new files are still labelled. node-exporter needs pod-level `seLinuxOptions.type: spc_t` + root + `CAP_SYS_PTRACE` for the filesystem collector to read `/host/proc/1/mountinfo` (container_t is denied by the ptrace LSM hook — dontaudited, so it shows as plain EACCES). Python/Node `io_uring` denials are audit spam with epoll fallback — fix with `PYTHON_IO_URING=0` / `UV_USE_IO_URING=0` rather than SELinux changes. `setroubleshootd` CPU pegged = denial backlog; fix the denials, don't mask.

### Accepted Security Tradeoffs

Accepted tradeoffs and resolved audit findings — do not re-flag without reading the referenced reasoning:

- **`adminadmin` qBittorrent password is accepted** (`targets/srv0/k3s-apps/templates/qbittorrent.yaml`) — the web UI sits behind forwardauth-authelia + geoblock + crowdsec; the password is an internal convenience, not a security boundary. Never propose "fixing" it.
- **NetworkPolicies ARE enforced** — K3s ships an embedded network-policy controller (kube-router) enabled by default; the repo never sets `--disable-network-policy` (the scripts set `flannel-backend: wireguard-native` only). Flannel being the data path does NOT mean policies are unenforced. Verify with `kubectl -n kube-system get pods | grep -i router` before claiming otherwise.
- **The authelia-header-gate is NOT forgeable** — in the `authelia-with-optional-header-gate` chain (`targets/srv0/k3s-base/templates/traefik.yaml`), `forwardauth-authelia` runs FIRST and, on any 2xx auth response, deletes client-supplied `Remote-User` and re-adds it only if Authelia's verify response contained it (Traefik v3 `pkg/middlewares/auth/forward.go`). `bypass` responses carry no `Remote-User`, so a forged header is stripped → the gate 401s. When Authelia is unreachable, forwardauth aborts the chain (500) before the gate runs. The only way `Remote-User` reaches the gate is genuine Authelia authentication. Do not re-flag the gate without reading the chain order.
- **SSH hardening is out of repo scope** — sshd/fail2ban hardening is done manually on the machines, pre-repo. Don't propose `harden-ssh`-style commands. The open SSH tunnel at vps0:8888 is mitigated by pubkey-only auth set up out-of-band.
- **Unpinned supply-chain fetches are accepted tradeoffs** — the dracut clone in `preboot.sh`, the etcdctl "latest" download in `update-node-ip`, `releases/latest` system-upgrade manifests, the TOFU K3s installer fetch (`get.k3s.io` over TLS, no local hash cross-check), and `get.docker.com` in `prereqs` are all deliberate: pinning them costs manual version bumps. Do not propose pinning.
- **vps0 `s01-whitelist` subnet regex stays** (`targets/vps0/compose/files/crowdsec/postoverflows/s01-whitelist/internal.yaml`) — uptime-kuma needs the exemption and its container IP isn't fixed; there is no better mechanism.
- **Authelia is deliberately NOT behind geoblock** (operator travels outside the CA/CN/CU allowlist). Crowdsec on the srv0 `auth` route is fine; geoblock is not.
- **Public-by-design services**: seerr (geoblock only, no SSO — deliberately shareable), cct26 on vps0 (fully open, no geoblock — deliberate), owncast RTMP ingest :1935 (relies on a strong stream key set in the Owncast admin UI, can't be Traefik-gated).
- **Public hosts deliberately without SSO and/or geoblock** — srv0: `gpt` (Open WebUI), `fmd`, and `rss` (FreshRSS) are public with geoblock + crowdsec only (their own app auth, no Authelia); `tv` (Jellyfin) has crowdsec + `authelia-with-optional-header-gate` + ratelimit but no geoblock. vps0: `plausible` (crowdsec only) and `ytdl` (metube; crowdsec + Authelia `one_factor`) have no geoblock. All deliberate — don't propose adding SSO or geoblock to any of these.
- **Home Assistant gets the ConBee II via CDI, not `privileged`** (`targets/srv0/k3s-base/templates/cdi-specs.yaml` + `k3s-apps/templates/homeassistant.yaml`) — the device cgroup blocks unprivileged opens of `/dev/ttyACM0`, so HA requests the `infra.local/devices-conbee` resource. The `cdi-specs` component runs cluster-wide: each node generates its own CDI spec in `/etc/cdi` from its actual `/dev` (grants follow the hardware, not a node label), and the `cdi-device-plugin` DaemonSet registers them. HA still needs pod-level `seLinuxOptions.type: spc_t` (SELinux denies `container_t` the mounted `/run/dbus/system_bus_socket` — Bluetooth integration → host bluez — and the device; verified empirically) plus `capabilities.add: [NET_ADMIN, NET_RAW]` (habluetooth manages the host adapter via direct HCI sockets; since hostNetwork was removed — auto-discovery unused — these apply to the pod netns only). Device cgroup access is scoped to the ConBee II alone. Don't propose re-adding privileged.
- **Jellyfin gets /dev/dri via CDI, not `privileged`** (`targets/srv0/k3s-apps/templates/jellyfin.yaml`) — requests `infra.local/devices-dri`, runs `container_t` as `$MY_UID`, no spc_t needed (renderD128 is 0666 + container_t-accessible). Device cgroup scoped to the render node. frigate/immich get the same grant (container_t + s0, pinned to srv0 — frigate keeps CAP_PERFMON but loses the dashboard GPU-stats graph: SELinux denies container_t perf_event_open); the CDI plugin runs spc_t instead of privileged; pvc-backup/restore pods are non-privileged (spc_t + DAC_OVERRIDE/FOWNER); ollama uses the `infra.local/devices-amd` grant (kfd + dri, bigpc) with container_t + s0; mosquitto runs as uid 1883. nfs-server ingress is allowlisted to the node CIDR on TCP 2049 (all shares nfsvers=4.2, CSI mounts are node-sourced).
- **nfs-server stays `privileged`** (`targets/srv0/k3s-base/templates/nfs-server.yaml`) — it runs a kernel NFS server (`nfsd`/`rpc.mountd`) in-container, which genuinely requires privileged. Internal base component, no ingress; don't propose de-privileging it.
- **vps0 Authelia `one_factor` rules are intentional** for ytdl/ikom/sale (family/guests); only the admin catch-all rule is `two_factor` (TOTP is Authelia's default second factor — no `default_second_factor_policy` needed).
- **srv0 PROXY-protocol trustedIPs include pod/service CIDRs on purpose** (`targets/srv0/k3s-base/templates/traefik.yaml`) — frpc connects to `127.0.0.1:8443`, but the port is served by a klipper-lb `svclb` pod (host network) which forwards to the Traefik Service; kube-proxy SNAT makes the Traefik pod see pod/service-CIDR sources, and the PROXY v2 header (emitted by vps0's Traefik `serversTransport frps-proxy`, in the `traefik_dynamic` config) rides inside the tunnel stream. Untrusted sources would leave the header unparsed and corrupt the TLS stream — narrowing below these CIDRs breaks `home.*`. Consequence accepted: any pod can spoof a PROXY header to the host port.
- **CrowdSec bouncer `clientTrustedIPs` is a client bypass-whitelist, not an XFF/proxy setting** (per the plugin README: "List of client IPs to trust, they will bypass any check from the bouncer or cache"). XFF trust is `forwardedHeadersTrustedIPs` (both stacks: `127.0.0.1/32` only). vps0 removed its `clientTrustedIPs: 172.19.0.0/24` — docker-network callers are exempted from decisions at the crowdsec layer via the `s01-whitelist` postoverflow instead. Don't reintroduce `clientTrustedIPs` to "fix" internal traffic.
- **Agents must never read `config/` or any of its files** — secrets are private by design; audits check gitignore coverage and git history, not file contents.

## Manual first-time setup (srv0 apps)

One-time web-UI setup steps for the apps that have no API seeding:

- **radarr / sonarr** (`https://radarr.$SERVICES_DOMAIN`, `https://sonarr.$SERVICES_DOMAIN`, Authelia-protected): General → Authentication → Forms (create admin account); Media Management → Root Folders (`/data/Movies` for radarr, `/data/TV` for sonarr); Download Clients → qBittorrent at `qbittorrent.apps.svc.cluster.local:8080` (credentials from the qBittorrent setup); Indexers via Prowlarr or manual; Connect → Jellyfin (`http://jellyfin.apps.svc.cluster.local:8096`, API key from the Jellyfin dashboard, notify On Import/On Upgrade). The arr API keys are pre-configured: `kubectl -n apps get secret radarr-secret|sonarr-secret`.
- **prowlarr** (`https://prowlarr.$SERVICES_DOMAIN`): Settings → Apps → add Radarr (`http://radarr.apps.svc.cluster.local:7878`) and Sonarr (`http://sonarr.apps.svc.cluster.local:8989`) with keys from their secrets; Settings → Indexers (auto-syncs to Radarr/Sonarr). For Cloudflare-protected indexers, add FlareSolverr (`http://flaresolverr.apps.svc.cluster.local:8191`).
- **seerr** (`https://seerr.$SERVICES_DOMAIN`): sign in with the Jellyfin account (`http://jellyfin.apps.svc.cluster.local:8096`); Settings → Services → add Jellyfin, Radarr, Sonarr (same URLs/keys as above).
- **Frigate → Home Assistant**: MQTT integration once (`broker: mosquitto`, `port: 1883`, `user: homeassistant`, password = `HA_MQTT_PASSWORD` from VARS), then the Frigate integration (`URL: http://frigate:5000`, internal unauth port). Frigate's MQTT discovery auto-creates camera/event entities; the dashboard is auto-provisioned (core cards only — no custom components; the Advanced Camera Card is installed by the HA `integration-update` init container, served at `/local/community/advanced-camera-card-2026/dist/...`). Recordings land on NFS (`$SECONDARY_STORAGE_PATH/frigate`). Gotchas: iframe embeds of the Frigate UI don't work (Authelia `X-Frame-Options: DENY`); the HA companion app may cache a stale frontend (clear app storage); if the rpi go2rtc password file is deleted, update `FRIGATE_RTSP_PASSWORD` in VARS and re-apply frigate.

## Updates (Renovate)

Renovate runs **automatically every day at 17:00 America/Toronto** as the `renovate` K3s CronJob on srv0 (base group, `targets/srv0/k3s-base/templates/renovate.yaml`) — the full `renovate/renovate` image (ships the Go toolchain, so the gomod manager works). The pod mounts only two files of the syncthing-synced repo (`config/VARS.env` and `.git/config`, read-only) to source `RENOVATE_GITHUB_TOKEN` (auto-rotates on sync) and to infer `RENOVATE_GIT_AUTHOR`; Renovate itself clones from GitHub. `bash scripts/renovate.sh [--dry-run]` is the manual/on-demand equivalent for other machines (needs Node/npm and `go` from prereqs for gomod updates; runs on the machine you're on, opening PRs directly on GitHub).

Review/apply flow (manual only for critical infra; automerge for everything else per scope below): fetch the PR branch (`git fetch origin pull/<n>/head:renovate/pr-<n>`, then `git checkout renovate/pr-<n>`), `bash scripts/validate.sh <target>`, then merge locally and `git push origin master`. Merges never happen in the platform UI — origin stays the source of truth. Renovate rebases its open PRs and auto-closes them once the change lands on `master` (next run).

**Automerge scope** — Renovate auto-merges anything *not* matching the critical-infra exclusion (packageRules `matchFileNames` + `matchUpdateTypes`). For critical infra — srv0 K3s base group (namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring), vps0 compose (public edge), and the srv0 frpc tunnel compose — only **major** updates stay manual; minor/patch automerges normally. Longhorn exception: patches automerge, but **minor** bumps are proposed without automerge (sequential minor upgrades are mandatory — never merge a minor skip). The grouped docker-digests PR is always manual (it mixes base images). Everything else — apps-namespace k3s components, pc/bigpc/rpi compose, unmanaged arr-stack dirs — automerges including majors (no CI gate; a merged change only deploys when you next run the deploy commands — `docker compose up -d` / `helm upgrade --install`).

**Watchtower vs Renovate ownership** — watchtower runs only on pc/bigpc and updates every local container *without* the `com.centurylinklabs.watchtower.enable=false` label — in practice just compose `syncthing/syncthing` (kept untagged; socket-proxy is labeled false). Renovate ignores `syncthing/syncthing` under the docker-compose manager only, so the srv0 K3s syncthing (pinned tag) stays Renovate-managed. Everything else is Renovate's (srv0/vps0/rpi have no watchtower at all). Watchtower's own image is digest-pinned by Renovate (`nickfedor/watchtower:latest`) since watchtower never self-updates.

`renovate.json` at root (repository config): built-in **kubernetes** manager (`managerFilePatterns: /^targets\/srv0\/k3s-(base|apps)\/.*\.ya?ml$/` — plain pod-spec images incl. the hook Jobs and vendored system-upgrade manifests) and **docker-compose** manager (all compose images) plus four regex managers, all retargeted to `targets/srv0/k3s-(base|apps)/.+\.ya?ml$`: (1) images inside HelmChart `valuesContent` blocks, (2) HelmChart CR versions (`oci://` via the docker datasource — the helm datasource has no OCI support — or `chart:`+`repo:`+`version:`), (3) K3s plan versions (`github-releases` on `k3s-io/k3s`, custom versioning), (4) Traefik plugin pins in `additionalArguments` (also covers vps0 compose). Global options (token, repo) are set by the runner script, not the repo config. packageRules: pin floating `latest|stable|release|alpine` tags (and every untagged compose image, which carries an explicit `:latest`) to digests and group all digest pins/refreshes into one PR (prHourlyLimit 20); block majors for `postgres`, `clickhouse/clickhouse-server`, `fedora` (the former inline `# PRESERVE_MAJOR` comments became package-level rules — Renovate can't read inline comments); disable syncthing (compose; watchtower-owned on pc/bigpc) and the frozen moving-sale site image. Longhorn minor PRs are never automerged (sequential minor upgrades required); immich's postgres image gets custom regex versioning (same-shape `18-vectorchordX.Y.Z-pgvectorA.B.C` tags only, postgres major locked via the compatibility group); the WASM plugin's go.mod is gomod-managed via the CronJob's Go toolchain. No other annotations — Renovate's default update decision applies everywhere.

Compose image ownership:
| Where | Updater |
|---|---|
| srv0 (frpc), pc/bigpc compose | Renovate PRs; watchtower (pc/bigpc) auto-updates only compose syncthing |
| vps0 compose (pinned or digest-pinned) | Renovate PRs (no watchtower on vps0) |
| Floating/untagged k3s + compose images | Renovate digest-pin PRs (tag stays, digest refreshed) |

Post-update: `git diff` → `bash scripts/validate.sh <target>` → deploy.

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
.gitignore                      # current_target/, backups, config/, targets/*/compose/{compose.private.yaml,.env}
.yamllint                       # lint config for the config templates + k3s chart YAML
renovate.json                   # Renovate repo config
scripts/                        # common.sh (env bootstrap + shared helpers) + the ops scripts:
                                #   validate.sh, compose-backup.sh, prereqs.sh, renovate.sh,
                                #   preboot.sh, wireguard.sh, k3s-server.sh, k3s-join.sh,
                                #   k3s-node-prep.sh, pvc.sh, update-node-ip.sh
config/                         # gitignored real values; mirrors targets/<t>/config_template/:
                                #   VARS.env (universal), srv0/{values.yaml,compose.env,frpc/},
                                #   vps0/{compose.env,frps/,authelia/users_database.yml}
targets/<target>/
  config_template/              # Documents every required variable + generation commands;
                                #   copy to config/<t>/ and fill in (values.yaml and/or
                                #   compose.env plus extra files like certs/users DB)
  compose/compose.yaml          # $VARIABLE placeholders (docker-compose native interpolation)
  compose/compose.private.yaml  # Optional gitignored overlay, merged over compose.yaml
  compose/files/                # Verbatim config files mounted :ro
  compose/.env                  # gitignored machine-fact env (written by prereqs.sh for every target)
  k3s-base/ k3s-apps/            # srv0 Helm charts (base + apps scopes): templates/ (repo-owned
                                #   components + HelmChart CRs + hook Jobs), k3s-base also: files/
                                #   (WASM plugin), plugins/ (WASM plugin source), geoip-src/;
                                #   values.yaml = committed defaults; secrets in config/srv0/values.yaml
current_target/compose_live_state/   # Runtime state (gitignored, ephemeral)
compose_state_backups/ k3s_state_backups/   # Backup archives (gitignored)
architecture.svg|.excalidraw        # Architecture diagram
```

## Environment variables (always available)

For the bash scripts: `$INFRA_ROOT` (repo root — self-computed by `scripts/common.sh` unless pre-set, so the in-cluster pods' pre-set values win), `$TARGET` (set by `require_target`/`require_target_host`), `$COMPOSE_STATE_DIR` (`current_target/compose_live_state`), `$PVC_BACKUP_DIR` (`k3s_state_backups`), `$MY_UID` (current UID, forced 1000 when root). Compose interpolation consumes `--env-file` (vps0/srv0) or the project-dir `.env` (pc/bigpc/rpi) — no repo-level env is needed for deploy commands.

## Rules

- **The target is always explicit** — target-selecting scripts (validate, compose-backup) take their target as the first argument; nothing infers it from the hostname.
- **Apply through the real commands** — `helm upgrade --install` for k3s, `docker compose up -d` for compose (node labels/taints at join time go through `k3s-join.sh`). Direct inspection (logs, get, describe, curl) is fine.
- **K3s node provisioning goes through `scripts/k3s-server.sh`/`k3s-join.sh` only** — never raw installers or ad-hoc joins; the scripts supply the installer and secret-handling setup. Dev-only lint (`yamllint`/`shellcheck`) touches nothing.
- Never edit files under `current_target/` (runtime state).
- Never commit secrets (`config/`, `compose.private.yaml`, `targets/*/compose/.env` are gitignored).
- New components must follow the sizing tiers and include NetworkPolicies.
