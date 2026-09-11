# AGENTS.md

## Overview

Infra is the infrastructure-as-code repo for a multi-machine homelab. Everything a target needs lives in `targets/<t>/`; shared logic sits in `scripts/`; secrets live in the gitignored `config/`. There is no build step.

Target-selecting scripts (`validate`, `compose-backup`) take `<target>` as their first argument; nothing infers it from the hostname. Machine-local scripts (`prereqs`, `renovate`, `preboot`, `wireguard`, `kubeconfig-unlock`, `k3s-server`, `k3s-join`) act on the machine they run on and take no target.

## Targets

`targets/` is authoritative — the table below can drift.

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + frpc Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, FRP server (frps), web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm) via agent node; syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

- **srv0** — k3s-base: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, crowdsec-web-ui, authelia, pvc-backup, ntfy, descheduler, system-upgrade, monitoring, generic-device-plugin, node-feature-discovery, node-facts. k3s-apps: immich, logtfy, jellyfin, navidrome, mdscl, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, dscpln, opencanary, flaresolverr, fmd, plik, syncthing, headlamp, frigate. The Compose sidecar is frpc only. Ollama runs on bigpc's AMD GPU; Open WebUI reaches it in-cluster only (no LAN exposure). Jellyfin, Immich ML and Frigate use srv0's Iris Xe iGPU; Frigate recordings stay on NFS deliberately so the pod can move nodes. Home Assistant's integration auto-installs on every pod start (no HACS).
- **bigpc** — K3s agent; the generic-device-plugin advertises the AMD GPU as `infra.local/amd`. Tainted `scheduling-discouraged` (PreferNoSchedule) and `create-default-disk=false` (no Longhorn replicas). Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host network).
- **vps0** — Compose runs frps, traefik, authelia + db, crowdsec, crowdsec-web-ui, plausible (app/ClickHouse/Postgres/state-fixperms), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, cct26, moving-sale, obtainium, and socket proxies. No watchtower here — Renovate owns every image (floating tags pinned by digest). Two zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`).
- **rpi** — go2rtc runs the official image untouched; a one-shot `go2rtc-init` service generates the stream password on first start and persists it in `current_target/compose_live_state/go2rtc/` (`password` file + `go2rtc.env`, consumed via compose `env_file`); the WebUI is loopback-only. `prereqs.sh` on rpi is a one-time machine bootstrap (Docker install + the go2rtc state bind dir owned by `$MY_UID`) — no `config_template/` and no machine-fact needs.

## Directory layout

```
.gitignore                    # ignores current_target/, backups, config/,
                              #   targets/*/compose/{compose.private.yaml,.env}
.yamllint                     # lint config for the config templates + k3s chart YAML
renovate.json                 # Renovate repo config
scripts/                      # common.sh (env bootstrap + helpers) + the ops scripts
config_template/VARS.env      # committed template for config/VARS.env (universal secrets)
config/                       # gitignored real values, mirroring targets/<t>/config_template/:
                              #   VARS.env, srv0/{values.yaml,compose.env,frpc/},
                              #   vps0/{compose.env,frps/,authelia/users_database.yml}
targets/<t>/
  config_template/            # every required variable + generation command (copy to config/<t>/)
  compose/                    # compose.yaml, optional gitignored compose.private.yaml,
                              #   files/ (verbatim :ro configs), .env (machine facts, from prereqs.sh)
  k3s-base/ k3s-apps/         # srv0 Helm charts; k3s-base also files/ (WASM plugin, alerting,
                              #   dashboards), plugins/ (plugin source), geoip-src/
current_target/compose_live_state/   # gitignored runtime state (ephemeral)
compose_state_backups/ k3s_state_backups/   # gitignored backup archives
architecture.svg|.excalidraw  # architecture diagram
```

## Prerequisites

Bash 4+, Python 3, Docker Compose v2, kubectl (K3s targets), helm (srv0), yq, jq, curl, openssl. Node.js/npm and `go` are needed for local `renovate` runs (npx + the gomod manager). Dev-only: `shellcheck`, `yamllint`.

`bash scripts/prereqs.sh` prepares the machine: packages (including Longhorn's iSCSI/NFS dependencies and `iscsid`), the pinned helm binary, the official Docker bootstrap, the generated machine-fact `.env`, host bind dirs, and the seeded `acme.json`. It is idempotent — re-run it after repo changes that add compose bind dirs.

## Bootstrap order

For a from-scratch setup:

1. **DNS + FRP certs first** — `$SERVICES_DOMAIN` must point at vps0, with `home.$SERVICES_DOMAIN` and `*.home.$SERVICES_DOMAIN` for the tunnel; create the FRP mTLS certs with the openssl commands in the template FRP sections. srv0's cert-manager uses HTTP-01, so it can't issue certs until the public path through vps0/frps exists.
2. **`scripts/prereqs.sh` on every machine** (see Prerequisites).
3. **Config** — `cp -r targets/<t>/config_template config/<t>` and fill every value; `cp config_template/VARS.env config/VARS.env`; point `INFRA_ROOT`, `PVC_BACKUP_DIR`, `MAIN_PARENT_DIR`, `MEDIA_DIR_PATH` etc. at the machine layout.
4. **Bring vps0 up before srv0** — `validate.sh vps0`, then compose up: srv0's ACME challenges need the edge already serving.
5. **srv0** — `validate.sh srv0` → `k3s-server.sh` → `kubeconfig-unlock.sh` → the frpc compose sidecar → `srv0-base` → `srv0-apps`. For a first bootstrap, flip `AUTHELIA_HEADER_GATE_ENABLED` to `"true"` and leave it there until Authelia reports Ready, then set it back to `"false"`.
6. **Add the other nodes** — run `k3s-join.sh` on the control plane once `srv0-base` is applied (the replica-count step needs Longhorn present).
7. **Machine-local extras** — `wireguard.sh`, `preboot.sh`.
8. **Post-deploy** — the manual first-time setup below (app seeding, crowdsec-web-ui machine registration).

The in-cluster jobs (`pvc-backup`, `renovate`) mount the repo from `INFRA_ROOT`, so the checkout can live anywhere (it need not be under `MAIN_PARENT_DIR/Main`).

## Commands

Each script resolves the repo root itself, so these run from anywhere. Run `validate.sh` before every `helm upgrade --install`.

```bash
# Preflight — read-only, any machine:
bash scripts/validate.sh srv0        # config completeness/placeholders + helm lint + both-chart render
bash scripts/validate.sh vps0        # compose.env + file completeness/placeholder check

# K3s (srv0) — the kubeconfig is root-only. Unlock it in another terminal:
# kubectl reaches it via the ACL on the k3s default path, helm via the ~/.kube/config symlink.
bash scripts/kubeconfig-unlock.sh    # Ctrl-C to lock; --lock cleans up leftovers
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
helm uninstall srv0-apps -n apps     # delete apps first, then srv0-base (PVCs retained)

# Compose — from the repo root, ON the target machine:
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  up -d --remove-orphans
docker compose --env-file config/vps0/compose.env --env-file targets/vps0/compose/.env \
  -f targets/vps0/compose/compose.yaml -f targets/vps0/compose/compose.private.yaml \
  down <svc>                         # then up -d <svc> to restart one service
docker compose --env-file config/srv0/compose.env --env-file targets/srv0/compose/.env \
  -f targets/srv0/compose/compose.yaml up -d      # frpc sidecar
# pc/bigpc/rpi: docker compose -f targets/<t>/compose/compose.yaml up -d
#   (no --env-file; the project-dir machine-fact .env auto-loads)

# Backups:
bash scripts/compose-backup.sh vps0  # tar compose state; [-e backup_remote=user@host:path] streams over SSH
bash scripts/pvc.sh backup --all -y  # PVC backup (or: backup <name>) — run during an unlock
bash scripts/pvc.sh restore --all -y # PVC restore (or: restore <name>) — run during an unlock
sudo bash scripts/update-node-ip.sh [--ip X] [--force]

# Machine-local (no target):
bash scripts/prereqs.sh
bash scripts/renovate.sh [--dry-run] # manual Renovate run (opens GitHub PRs)
bash scripts/preboot.sh frpc|crypt-ssh
bash scripts/wireguard.sh <path/to/wg0.conf>
bash scripts/k3s-server.sh           # bootstrap THIS machine as the control plane
bash scripts/k3s-join.sh <node_ip> <node_user> \
  [--role agent|server] [--scheduling-discouraged] [--longhorn-replicas]   # ON the control plane

# Dev-only lint:
shellcheck $(find scripts targets -name '*.sh' -not -path '*/plugins/*')
yamllint -c .yamllint targets/*/config_template \
  targets/srv0/k3s-base/values.yaml targets/srv0/k3s-base/Chart.yaml targets/srv0/k3s-base/files \
  targets/srv0/k3s-apps/values.yaml targets/srv0/k3s-apps/Chart.yaml
```

Scripts warn or hard-fail (`require_target_host`) on hostname/target mismatches. Pass `-y` to PVC commands for non-interactive confirmations.

Ad-hoc diagnostics (run on the srv0 control plane):

- Shell into a throwaway pod with a PVC and a hostPath mounted: `kubectl run pvc-shell --rm -it --restart=Never -n <ns> --image=ubuntu:24.04 --overrides='{"spec":{"containers":[{"name":"s","image":"ubuntu:24.04","stdin":true,"tty":true,"command":["bash"],"volumeMounts":[{"name":"pvc","mountPath":"/pvc"},{"name":"host","mountPath":"/host"}]}],"volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"<pvc>"}},{"name":"host","hostPath":{"path":"/tmp/pvc-transfer"}}]}}'`
- NFS write/read smoke test against the shared RWX backup PVC (`pvc-backup-dest` in `base`): `kubectl run storage-test --rm -i --restart=Never -n base --image=busybox:1.36 --overrides='{"spec":{"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c","echo ok > /mnt/t && cat /mnt/t && rm /mnt/t"],"volumeMounts":[{"name":"d","mountPath":"/mnt"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"pvc-backup-dest"}}]}}'`

## Scripts

### Inventory

| Script | Selects | Acts on | Notes |
|---|---|---|---|
| `validate.sh <t>` | target | read-only, any machine | config_template→config completeness/placeholders, helm lint + both-chart render (srv0), compose `../../../config/` mount check. Prints variable names only. |
| `compose-backup.sh <t>` | target | ON the target (hostname asserted) | tars compose state via an Alpine container; `-e backup_remote=user@host:path` streams the tar over SSH |
| `prereqs.sh` | — | this machine | packages (Longhorn iSCSI/NFS + `iscsid`), pinned helm, Docker bootstrap, machine-fact `.env`, host bind dirs, acme seed |
| `kubeconfig-unlock.sh [--lock]` | — | this machine | read ACL on the k3s kubeconfig + `~/.kube/config` symlink; holds until Ctrl-C; `--lock` cleans up |
| `renovate.sh` | — | this machine (opens GitHub PRs) | needs `RENOVATE_GITHUB_TOKEN` in `config/VARS.env` |
| `preboot.sh frpc\|crypt-ssh` | — | this machine | initramfs LUKS unlock; frpc certs from `config/<hostname>/frpc/` |
| `wireguard.sh <conf>` | — | this machine | deploys a provider wg0.conf (split-/1 routes, endpoint dead-loop route) |
| `k3s-server.sh` | — | this machine (becomes control plane) | node prep + installer + server config + Longhorn default-disk label |
| `k3s-join.sh <ip> <user> [...]` | — | control plane + joining node | token travels via stdin over SSH; taint/Longhorn after Ready |
| `k3s-node-prep.sh` | — | the node (root) | sysctls, firewall — shared by server/join |
| `pvc.sh` | — | the cluster (or in-cluster pod) | PVC backup/restore |
| `update-node-ip.sh` | — | the node | K3s node IP change |

### Writing a script

New target-selecting logic goes in `scripts/` (shared/generic) or at the target root (`targets/<t>/foo.sh`) when it serves one target; machine-local logic takes no target. Every script uses the same shape: `#!/bin/bash`, a `# DESC:` second line, `set -euo pipefail`, a `usage()` function, and the common.sh bootstrap:

```bash
if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
```

The bootstrap self-computes the repo root but honors a pre-set `INFRA_ROOT` (the in-cluster pods ship it, and their host paths must not be recomputed). Target-selecting scripts call `require_target "$1"` (warns on hostname mismatch — check flows) or `require_target_host "$1"` (hard-asserts — ops that mutate the machine). Useful `common.sh` helpers: `_confirm`, `get_sudo_cmd`, `get_node_ip`, `wait_for_k3s_cluster`, `set_my_uid`.

### Comment & doc rules

- Explain current behavior and non-obvious WHYs only — never history ("used to", "previously", "replaces the old X"). Past designs live in git history.
- Keep comments minimal: file headers say what the file IS; don't restate code or narrate steps.
- No device names (srv0/vps0/bigpc/pc/rpi) in shared code (`scripts/`) — keep it generic ("the frpc preboot reads certs from `config/<hostname>/frpc/`", not "from srv0's certs"). Per-device facts belong in `targets/<t>/`; README.md and AGENTS.md are the only shared files that may name targets.
- Docs describe the current codebase only; delete migration/historical notes once a migration lands.
- After editing, `grep -rniE 'the old|previously|formerly|replaces the old|is gone' scripts targets` should return nothing but legitimate current-behavior notes.

## Configuration & secrets

- **Layout** — `targets/<t>/config_template/` (committed) documents every secret input: `values.yaml` (k3s helm values) and/or `compose.env` (compose dotenv), plus extra files (mTLS certs, the Authelia users DB). Copy it to `config/<t>/` and fill every value; `config/<t>/` mirrors the template structure exactly and is gitignored. Templates carry generation commands where possible (e.g. `openssl rand -hex 32`); `validate.sh` rejects leftover placeholders.
- **srv0 — split by consumer** — `config/srv0/values.yaml` feeds only the k3s charts (both, via `helm upgrade -f`). The frpc sidecar takes `config/srv0/compose.env` (`PROXY_HOST`, `TLS_SERVER_NAME`, passed with `docker compose --env-file`) and its mTLS certs as real 0600 files under `config/srv0/frpc/`. The template's `values.yaml` documents every YAML key plus the env/cert layout in its FRP section.
- **vps0 — dotenv only** — `config/vps0/compose.env` is consumed natively by compose via `--env-file`; no conversion or render step. Multi-line secrets are not dotenv values: the Authelia users DB is `config/vps0/authelia/users_database.yml` and the frps certs are 0600 files under `config/vps0/frps/` (mounted `:ro`). Machine facts come from the prereqs-generated `targets/vps0/compose/.env`, passed as a second `--env-file` (later file wins).
- **pc/bigpc/rpi — machine facts only** — no `config_template/` (no secret variables). `prereqs.sh` writes `targets/<t>/compose/.env` with `MY_UID`/`DOCKER_GID`/`MY_USERNAME` for **every** target (config envs never carry per-machine facts): vps0/srv0 pass it as a second `--env-file`, pc/bigpc/rpi get it auto-loaded as the project-dir `.env`.
- **No encryption** — values sit as plain text under the gitignored `config/`.
- **Format** — values.yaml: `KEY: value`; multi-line values are literal block scalars (`|`), spliced verbatim by helm (`| indent "N"`); inline comments work after single-line values; bare `$` and `#` are literal (write `$argon2id$...` unescaped). compose.env: `KEY=value`; single-quote values containing `$` (compose interpolates inside double quotes); multi-line values use `\n` escapes; inline comments work after single-line values.
- **Validation** — `validate.sh <target>` asserts every template file has a filled counterpart at the same relative path, rejects placeholders (`change_me`/`changeme`/`abc`/`REPLACE_ME`/`<...>`), checks key completeness for values.yaml/compose.env, verifies compose `../../../config/` mounts exist, and for srv0 lints + templates both charts (missing values surface as `<no value>` render failures).
- **Universal VARS** — target-agnostic secrets live in `config/VARS.env` (dotenv; template `config_template/VARS.env`). Commands load it on demand (`renovate.sh` requires `RENOVATE_GITHUB_TOKEN`; the in-cluster renovate CronJob does `set -a; . /repo/config/VARS.env`). It is not template-validated — each command checks its own variables.
- **mTLS certs** — generated with the copy-paste `openssl` commands in the FRP sections of the templates (per-pair CA, server/client certs, preboot client cert); PEMs live as real files under `config/<t>/frpc/` and `config/vps0/frps/`.
- **`*_HASHED` (k3s authelia)** — precomputed hashes stored in the same YAML next to their `*_HASHABLE` plaintexts (`openssl passwd -6` or `authelia crypto hash generate pbkdf2`; commands are in the template).

## Compose

- **Files** — `targets/<t>/compose/compose.yaml` plus an optional gitignored `compose.private.yaml` merged with `-f`. Substitution is native docker compose: `$VAR` values come from `--env-file config/<t>/compose.env` on vps0/srv0, or from the automatically loaded project-dir `.env` on pc/bigpc/rpi. Project name = the `name: <t>` attribute.
- **Inlined configs** — templated configs (frpc.toml, authelia configuration.yml, the traefik dynamic config, crowdsec notifications/whitelist, logtfy config.json) are top-level `configs:` blocks using `content:` with `$VAR` interpolation (or an `environment: VARNAME` source), granted via the `configs:` long syntax with `target:` and `mode:` (0400 for secret-bearing, 0440 otherwise). Static files — frps.toml, crowdsec acquisitions/profiles, auth.py, clickhouse-config.xml, go2rtc.yaml — live in `targets/<t>/compose/files/` and are bind-mounted `:ro`.
- **State** — `current_target/compose_live_state/` (gitignored) holds runtime state only (acme.json, sqlite DBs, upload dirs), referenced with relative paths (`../../../current_target/compose_live_state/...`, resolved against the compose file's directory). `prereqs.sh` creates missing bind dirs owned by `$MY_UID` (Docker would create them as root, unwritable by containers running as `$MY_UID`) and seeds `traefik/acme.json` (`{}`, 0600, first run).
- **Ownership self-heal** — containers with a fixed non-`$MY_UID` user (ClickHouse 101, Plausible 999) have a one-shot `state-fixperms` init service (alpine, `cap_drop: ALL` + `CHOWN`/`FOWNER`/`DAC_OVERRIDE`) that chowns their state dirs before the apps start; dependents gate on it with `condition: service_completed_successfully`. It re-runs after `docker compose down <svc>`, so host-side chown drift is fixed on the next deploy.
- **Deploy** — see Commands; reboot survival comes from per-service `restart:` policies (no systemd wrapper).
- **Backup** — `compose-backup.sh <t>` tars the state locally via an Alpine container (skips FIFOs/sockets) and prunes to `$BACKUP_RETENTION` (default 1); with `-e backup_remote=user@host:path` it streams the tar over SSH into `compose_state_backups/` (the remote runs docker directly — no scripts needed there). It asserts `hostname == target` via `require_target_host`; plain `docker compose` runs are your own guard (deploy from the target's own checkout).

## K3s & Helm

### Charts and releases

Two sibling charts — `targets/srv0/k3s-base/` and `targets/srv0/k3s-apps/` — applied with `helm upgrade --install`. They produce `srv0-base` (namespace `base`) and `srv0-apps` (namespace `apps`). Apply `base` before `apps`; delete in reverse (`srv0-apps` first) — Helm retains PVCs on uninstall. `validate.sh srv0` is the preflight.

The charts contain: (a) every repo-owned component as a Helm template — secrets, configmaps, ingresses, PVCs, cronjobs, the Traefik Middlewares/HelmChartConfig, and the WASM plugin ConfigMap via `.Files.Get`; (b) the 20 upstream-app `HelmChart` CRs (12 base, 8 apps), owned by helm-controller, which avoids release-name-derived resource naming; (c) vendored system-upgrade-controller manifests + Plans; (d) the immich seeding hook.

Templates are one file per component under `templates/`, using native `{{ .Values.X }}` refs and `| indent "N"` for multi-line values; secrets and configmaps sit in `prereqs` sections next to their `IngressRoute`s and `NetworkPolicy`s. `k3s-base/` also carries `files/` (WASM plugin + traefik-plugin-config), `plugins/` (plugin source), and `geoip-src/` (geoip helper image source). `Chart.yaml` is name/version only; `values.yaml` holds just the committed machine-independent defaults (`MY_UID`).

`k3s-apps/templates/hooks.yaml` is the one seeding Job (`immich-seed`), annotated `helm.sh/hook: post-install,post-upgrade` with `hook-delete-policy: before-hook-creation,hook-succeeded` and RBAC through the `helm-hooks` ServiceAccount/Role. It skips when the admin already has an OAuth identity (`immich-admin list-users`, no auth needed); on a fresh DB it creates the admin through the sign-up API and persists the generated password in the `immich-seed-admin` Secret (apps) so later runs authenticate via the API — no interactive prompts. Other first-boot seeding is declarative: qBittorrent via a `qBittorrent.conf` ConfigMap + copy-once initContainer (`k3s-apps/templates/qbittorrent.yaml`), and GeoLite2 via the geoip Deployment's `geoipupdate` initContainer (a weekly CronJob keeps it current).

### Helm model

The helm binary is pinned by `prereqs.sh`; `upgrade --install` is idempotent (a three-way merge against the last stored manifest).

Three distinct "helm" layers:

1. **Our charts** → `srv0-base` / `srv0-apps`, via `helm upgrade --install` (see Commands).
2. **k3s's embedded helm-controller** → the 20 `HelmChart` CRs inside our charts. Our releases only apply the CR objects; the controller installs and upgrades the app releases (frigate, immich, …). `helm uninstall srv0-*` does not touch them — `kubectl delete helmchart` triggers their uninstall.
3. **k3s bootstrap charts** (traefik + traefik-crd in `kube-system`) — not ours; customized only through the `HelmChartConfig` template.

helm-diff is installed, so `helm diff upgrade` previews work.

### Pitfalls

- `helm lint`/`helm template` need both values files (`-f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml`; the same config file feeds both charts). Without them `.Values.X` is nil and lint fails with `invalid value; expected string`. Missing keys render as `<no value>` — `validate.sh` catches those.
- `.Files.Get` paths are chart-root-relative; the `files/` prefix is mandatory. Omitting it silently renders empty.
- Literal `{{` is interpreted by helm — homeassistant's embedded Go templates are escaped as `{{ "{{" }}`.
- Subchart resource names derive from `{{ .Release.Name }}` — the reason the app charts stay HelmChart CRs (helm-controller-managed) instead of becoming umbrella dependencies.
- Never `helm install --force` casually — it deletes and recreates resources.
- Don't validate rendered output with `kubectl apply --dry-run=server` (it trips on the 256KiB `last-applied-configuration` cap); use helm's own `--dry-run=server`.
- Adoption: pre-existing objects need `app.kubernetes.io/managed-by: Helm` plus the `meta.helm.sh/release-name`/`release-namespace` annotations, or helm refuses to install over them.
- `helm uninstall` ignores live-object annotations — `helm.sh/resource-policy: keep` only takes effect from the stored manifest.

### Kubeconfig access

`/etc/rancher/k3s/k3s.yaml` is `0600 root:root` (k3s sets `write-kubeconfig-mode: "0600"`), so users have no standing access. `scripts/kubeconfig-unlock.sh` grants the invoking user a temporary read ACL on it and symlinks `~/.kube/config` to it, blocking until Ctrl-C removes both (`--lock` cleans leftovers). A k3s restart rewrites the kubeconfig and clears the ACL mask — re-run the unlock afterwards. Host-side `pvc.sh` runs also belong inside an unlock session; the in-cluster CronJob uses its own ServiceAccount.

### Node provisioning

Owned by `k3s-server.sh` and `k3s-join.sh` (official get.k3s.io installer). Cluster policy lives in the scripts:

- **`k3s-server.sh`** (no args, on the node): runs `k3s-node-prep.sh` (sysctls in `/etc/sysctl.d/90-k3s.conf`; firewalld/ufw rules including 51820–21/udp for flannel-wg), the installer, and `/etc/rancher/k3s/config.yaml` (`selinux: true`, `write-kubeconfig-mode: "0600"`, `flannel-backend: wireguard-native`, the flannel-iface regex, `cluster-init: true`, `node-ip`), then restarts, waits for the server token and the API, and applies the Longhorn default-disk label. Node feature labels are NFD-managed (see Security). K3s needs a fixed IP; if it changes, run `scripts/update-node-ip.sh`.
- **`k3s-join.sh <node_ip> <node_user> [...]`** (on the control plane; the sudo prompts for the control plane and the joining node are separate, as they may differ): reads the token from `/var/lib/rancher/k3s/server/token`, resolves the server IP, streams `k3s-node-prep.sh` + the installer over SSH with the token appended on stdin (never argv — it lands in the node's root-only `k3s-agent.service.env` for agents, or `config.yaml` for joined servers), waits for the node to appear and become Ready, then applies the taint / Longhorn replica count. Flags: `--role agent|server`; `--scheduling-discouraged` (PreferNoSchedule taint); `--longhorn-replicas` (`create-default-disk=true` + auto-increments `default-replica-count`, guarded by the label's actual change so re-runs don't double-count; absent the flag → `create-default-disk=false`). The installer runs only when k3s is missing, so re-provisioning never fights system-upgrade-controller's version ownership. SSH host-key checking stays at the default (on): the first join prompts to accept the fingerprint, the same trust model as plain `ssh`.
- **`update-node-ip.sh`** (bash, on the node): sed-replaces `node-ip` in drop-ins and adds `50-node-ip.yaml`; updates etcd member peer URLs *before* restarting k3s (k3s is `Type=notify` — a synchronous restart deadlocks), restarts with `--no-block`, then patches the node's flannel public-ip annotation and status addresses. Installs etcdctl on demand.

### system-upgrade

The controller manifests are vendored in `templates/base/system-upgrade-controller.yaml` (downloaded from `releases/latest` of rancher/system-upgrade-controller; bump by re-downloading `crd.yaml` + `system-upgrade-controller.yaml` and replacing the template — the controller image inside is Renovate-managed via the kubernetes manager). `server-plan`/`agent-plan` versions (`vX.Y.Z+k3sN`) are Renovate-managed by the plan-version regex. Once bumped: apply `srv0-base`, then inspect with `kubectl -n system-upgrade get plans,jobs`.

### valuesSecrets

HelmChart CRs can pull values from a namespaced Secret via `spec.valuesSecrets: [{name, keys}]`: each listed key is projected as a `values-0-00N-HelmChart-ValuesSecret.yaml` file merged after `valuesContent` (plain Helm deep-merge, later file wins; `keys` must be non-empty). Used by frigate and loki. Secret changes re-trigger the chart upgrade (`ignoreUpdates: false` default). The Secret must live in the CR's namespace and must not be named `chart-values-<chart>`.

### Authelia header gate (srv0)

`AUTHELIA_HEADER_GATE_ENABLED` is a VARS knob (default `"false"`, pass-through; Bootstrap order covers the first-run `"true"`). The local TinyGo WASM plugin `authelia-header-gate` (loaded via `--experimental.localplugins`, shipped in the `traefik-local-plugins` ConfigMap) returns 401 for any request lacking a `Remote-User` header; its `blocking` field comes from the VARS value. Services that should bypass Authelia while still passing the gate use the `authelia-with-optional-header-gate` chain (bypass + gate). vps0 doesn't use the gate.

## Networking

- **Traefik on srv0** — two secure entrypoints: `websecure:443` (LAN, no proxy protocol) and `websecure-proxy:8443` (PROXY protocol v2; trustedIPs are `127.0.0.1/32` plus the pod/service CIDRs, since Klipper SNAT makes traffic appear to come from those). Routes for public services bind both entrypoints; `*.home.local` routes bind only `websecure`. Available middlewares: `geoblock` (allowlist plugin, self-hosted MaxMind GeoLite2 via the `geoip` component's `geoip-service`), `crowdsec-bouncer` (stream mode + AppSec on `:7422`), `forwardauth-authelia`, `lan-whitelist` (RFC1918), `cluster-only` (10.42/16), `basicauth-cluster`, `local-no-store`. HTTP → HTTPS redirect; readTimeout=0 on both secure entrypoints (streaming). Plugin versions are pinned in `additionalArguments` and regex-managed through `github-releases`.
- **vps0 edge** — one Traefik routes by Host/SNI: local services via Docker labels (two zones, see Targets); `home.$SERVICES_DOMAIN` + wildcard goes through the file provider (the `traefik_dynamic` compose config) to `frps:8080` (HTTP) / `frps:8443` with `tls.passthrough` — vps0 never terminates srv0's TLS; cert-manager on srv0 owns the LE lifecycle. cert-manager on srv0 additionally maintains a local chain (self-signed → `k3s-local-ca` → `ca-issuer`) for `*.home.local` and MQTT TLS.
- **FRP** — frps on vps0 (7000 control, 8887 preboot SSH, 8888 SSH; healthcheck on admin API `:7500`). The frpc sidecar on srv0 (host network, `pgrep` healthcheck) proxies ssh→8888, http→8080, https→8443 (local), and qbittorrent peer 56881 tcp+udp. Mutual TLS with a per-pair CA (openssl commands in the FRP sections of the VARS templates; certs under `config/<t>/frpc|frps/`); the preboot frpc uses a separate client cert.
- **WireGuard** (`wireguard.sh`, machine-local) — deploys a provider `wg0.conf`. It parses the provider conf (PrivateKey/Address/DNS/MTU/ PresharedKey/Endpoint — values never echoed), rewrites `AllowedIPs` to `0.0.0.0/1, 128.0.0.0/1` (split tunnel: less specific than LAN routes, so K3s subnets and LAN stay direct), and adds PostUp/PreDown `/32` routes for the endpoint via the physical gateway (dead-loop fix). Installs `wireguard-tools`, writes the 0600 `/etc/wireguard/wg0.conf`, and enables `wg-quick@wg0` (config changes apply via `wg syncconf`).
- **LUKS preboot** (`preboot.sh <frpc|crypt-ssh>`, on the node) — srv0 (frpc): reads the mTLS certs from `config/srv0/frpc/` and `PROXY_HOST`/`TLS_SERVER_NAME` from `config/srv0/compose.env`, resolves `PROXY_IP` itself (`getent hosts`), generates the frpc-preboot config, and installs an initramfs frpc tunnelling SSH via FRPS on 8887. bigpc (crypt-ssh): dropbear patched to `preboot_port` for direct LAN unlock (ethernet only). Re-run on srv0 after rotating preboot mTLS certs. When adding initramfs networking, verify with `lsinitrd` that firmware actually made it in — drivers don't retry firmware loads after pivot_root.

## Storage & PVC backups

- **Longhorn** backs the default StorageClass (replica count 1, best-effort locality, 2000% over-provisioning; minor upgrades must be done sequentially). Shared host data uses NFS (`nfs-server` + `csi-driver-nfs`) and static hostPath PV/PVC pairs (`host-volumes`, RWX, bound to the `infra.local/hostpath-main` label). Expect the `longhorn-manager` warning `Failed to get filesystem device type of /var/lib/longhorn/` on LUKS nodes — device-mapper volumes show up in sysfs as `dm-N` rather than their `luks-*` name; it only fires during disk-count reconciliation and does no harm.
- **Backup** — `pvc-backup` (base) is a nightly 3AM CronJob running `scripts/pvc.sh backup --all -y` in-cluster (bitnami/kubectl:latest, hostPath mounts of `$INFRA_ROOT` + `$PVC_BACKUP_DIR`, nodeSelector `infra.local/hostpath-main`). Archiving covers PVCs with the `auto-backup: "true"` label; the `backup.infra/exclude` annotation contributes tar `--exclude` patterns. A temp pod (scheduled on the volume's node for RWO; tolerates `scheduling-discouraged`) tars the live PVC (no scale-down) to the shared `pvc-backup-dest` PVC — a static PV bound to the ROOT of the NFS backups share (= `$PVC_BACKUP_DIR`), so archives land at their final human-named path `<name>.tar.gz` (with `__backup_timestamp.txt` inside), overwritten each run, reachable from any node.
- **Restore** — scales down every workload using the PVC (Deployments/StatefulSets only; replica counts recorded), waits for pods, restores via a privileged temp pod, then scales back up. `--all` does a bulk scale-down first.
- Backup and restore pods both need **pod-level** `seLinuxOptions.level: s0` (details under SELinux).

## Alerting (Grafana → ntfy)

- Grafana provisions one webhook contact point (`ntfy`, write-only token in the `grafana-alerting-contact` Secret from `NTFY_WRITE_ONLY_ACCOUNT_TOKEN`) plus file-backed alerting config from the `grafana-alerting-rules` ConfigMap: 15 rules (`files/alerting/rules.yaml`), the policy tree (`policies.yaml` — receiver ntfy, `group_by: alertname`, 12h repeat), and the markdown body template group (`templates.yaml`, `ntfy.body`). The Longhorn chart's ServiceMonitor is scraped via k8s-monitoring `prometheusOperatorObjects`; the additive `allow-monitoring-longhorn-manager` NetworkPolicy admits the collector on `:9500`.
- The templated webhook URL carries the dynamic ntfy fields (Extra Headers can't change per alert): `title` = alertname, `priority` = low on resolved / high on warning / urgent on critical / default otherwise, `markdown=yes`. `ntfy.body` renders the markdown body — state + name, summary, and the labels worth seeing — instead of the default `Value:`/`Labels:` dump.
- Title URL-encoding order matters: `%`→`%25` first, then spaces→`%20` (the reverse re-escapes the `%` of `%20`).

## Security

- Secrets never touch git (`/config/`, `compose.private.yaml`, `targets/*/compose/.env` are gitignored); `.secret`-style files are 0600 host files. Authelia SSO (forward-auth + basic-auth, 2FA); CrowdSec (srv0: Helm chart with agent/LAPI/AppSec + per-service postoverflow whitelists; vps0: single container, bouncer key auto-registered from `BOUNCER_KEY_TRAEFIK`); geoblock allowlist (CA/CN/CU); per-component NetworkPolicies plus baselines in the `namespaces` component (its kube-system policy explicitly allows 80/443/8000/8443 to Traefik).
- Docker socket via `wollomatic/socket-proxy`: `dockerproxy` (read-only, Traefik/monitoring) and `dockerproxy_priv` (read-write, watchtower; only on pc/bigpc — `cap_drop: ALL`, `read_only: true`, `mem_limit: 512M`, user `65534:$DOCKER_GID`).
- **Known tradeoff** — K3s `HelmChart` `valuesContent` (DB passwords, JWKS, OIDC secrets) is readable by anyone with `get` on `helmcharts.helm.cattle.io`; fine for single-user, but audit before granting namespace access. Where a chart exposes a secret ref it is used: authelia (`path:`), crowdsec (`externalSecret`), grafana (`admin.existingSecret`), headlamp (`oidc.externalSecret`), immich/nextcloud/plik (`secretKeyRef` in plain YAML). Where a chart has no secret-ref support but takes plain YAML, the component uses `spec.valuesSecrets`: values live in a namespaced Secret (e.g. `targets/srv0/k3s-apps/templates/frigate.yaml`, key `values.yaml`) listed in the CR, projected as a later `-f` values file so the merge is plain Helm deep-merge and renders identically. Done for **frigate**'s `env` passwords (its `env` key only accepts plain strings — chart limitation). What can't be avoided: authelia's JWKS PEM has to be embedded as `value:` (the chart otherwise generates a fresh RANDOM key when `CryptographicKey` isn't inline). freshrss stays a root container (the official image hardcodes apache on :80 and its entrypoint runs as root — de-rooting needs a custom apache config); nextcloud stays root too (the official entrypoint writes `/etc/apache2` as root even with `APACHE_PORT` set — uid 33 crashes on `remoteip.conf` removal; the PVC is already www-data-owned, so this is purely an entrypoint limitation).
- **SELinux (Fedora nodes)** — Kubernetes assigns per-pod MCS categories, and files keep their creator's categories forever. Any pods that share a hostPath tree (syncthing/mdscl/dscpln), plus the backup/restore pods, need **pod-level** `seLinuxOptions.level: s0` — the container-level setting is ignored. `privileged: true` sidesteps enforcement, but newly written files still get labelled. For its filesystem collector to read `/host/proc/1/mountinfo`, node-exporter needs pod-level `seLinuxOptions.type: spc_t`, root, and `CAP_SYS_PTRACE` (the ptrace LSM hook rejects container_t; because the denial is dontaudited it surfaces only as EACCES). Python/Node `io_uring` denials are audit spam with an epoll fallback — fix with `PYTHON_IO_URING=0` / `UV_USE_IO_URING=0`, not SELinux changes. `setroubleshootd` pegging CPU means a denial backlog; fix the denials, don't mask.

### Accepted security tradeoffs

Resolved audit findings and deliberate choices — don't re-flag any of these without reading the referenced reasoning.

- **qBittorrent's `adminadmin` password is fine** (`targets/srv0/k3s-apps/templates/qbittorrent.yaml`) — the UI is already gated by forwardauth-authelia + geoblock + crowdsec, so the password is convenience, not a boundary. Never propose changing it.
- **NetworkPolicies are enforced** — K3s embeds the kube-router network-policy controller and enables it by default; nothing here passes `--disable-network-policy` (the scripts only set `flannel-backend: wireguard-native`). Flannel carrying the data path does not disable policy enforcement. Check `kubectl -n kube-system get pods | grep -i router` before disputing this.
- **The authelia-header-gate cannot be forged** — the `authelia-with-optional-header-gate` chain (`targets/srv0/k3s-base/templates/traefik.yaml`) puts `forwardauth-authelia` first; on any 2xx auth result Traefik v3 (`pkg/middlewares/auth/forward.go`) strips a client-supplied `Remote-User` and only re-adds it when Authelia's verify response carried one. A `bypass` response has no `Remote-User`, so forged headers vanish and the gate answers 401. If Authelia is down, forwardauth fails the chain (500) before the gate is reached. Genuine Authelia auth is the only path that gets `Remote-User` to the gate. Read the chain order before re-flagging.
- **SSH hardening lives outside this repo** — sshd/fail2ban are configured manually per machine; don't suggest `harden-ssh`-style tooling. vps0:8888 being reachable is covered by pubkey-only auth configured out-of-band.
- **Unpinned supply-chain fetches are deliberate** — the dracut clone in `preboot.sh`, the "latest" etcdctl download in `update-node-ip`, the `releases/latest` system-upgrade manifests, the TOFU `get.k3s.io` installer fetch (TLS only, no local hash), and `get.docker.com` in `prereqs`. Pinning each would force manual version bumps; don't propose it.
- **The `s01-whitelist` subnet regex on vps0 stays** (`targets/vps0/compose/files/crowdsec/postoverflows/s01-whitelist/internal.yaml`) — uptime-kuma needs the exemption, its container IP is not fixed, and nothing better exists.
- **Authelia intentionally sits outside geoblock** — the operator travels beyond the CA/CN/CU allowlist. Crowdsec guards the srv0 `auth` route; geoblock would lock the operator out.
- **Public by design**: seerr (geoblock only — meant to be shareable, no SSO), vps0's cct26 (wide open, no geoblock), and owncast's RTMP ingest on :1935 (protected only by a strong stream key set in the Owncast UI; Traefik can't gate it).
- **Hosts that intentionally skip SSO and/or geoblock** — on srv0, `gpt` (Open WebUI), `fmd`, and `rss` (FreshRSS) are public behind geoblock + crowdsec only (they have their own auth, no Authelia); `tv` (Jellyfin) uses crowdsec + `authelia-with-optional-header-gate` + ratelimit but no geoblock. On vps0, `plausible` (crowdsec only) and `ytdl` (metube; crowdsec + Authelia `one_factor`) skip geoblock. Don't propose adding SSO or geoblock to any of them.
- **Home Assistant reaches the ConBee II through the generic-device-plugin, not `privileged`** (`targets/srv0/k3s-base/templates/generic-device-plugin.yaml` + `k3s-apps/templates/homeassistant.yaml`). The device cgroup forbids unprivileged opens of `/dev/ttyACM0`, so HA asks for the `infra.local/conbee` resource. The plugin DaemonSet (squat/generic-device-plugin) scans each node's `/dev` — grants track the hardware rather than a node label — and publishes stable IDs derived from the device path; a node without the device advertises zero. HA also requires pod-level `seLinuxOptions.type: spc_t` (container_t is denied the mounted `/run/dbus/system_bus_socket` — Bluetooth integration via host bluez — and the device) and `capabilities.add: [NET_ADMIN, NET_RAW]` (habluetooth talks to the host adapter over direct HCI sockets; with hostNetwork off and auto-discovery unused, these are scoped to the pod netns). The device cgroup grant covers only the ConBee II. Don't propose bringing back privileged.
- **NFD owns the node labels** (`targets/srv0/k3s-base/templates/node-feature-discovery.yaml` + `node-facts.yaml`) — the NFD chart (namespace `node-feature-discovery`) publishes the `node-facts` DaemonSet's local feature files as labels: `infra.local/hostpath-main` (when `$MAIN_PARENT_DIR/Main` exists) and `infra.local/external-exposed` (while an `frpc` process runs). The detector refreshes every 60s, writes atomically into the shared host `features.d` dir, and removes a label when its fact disappears. It only mounts host `/proc` read-only (reaching host root through `/proc/1/root` rather than mounting `/`) with pod-level `spc_t` + `SYS_PTRACE` for the ptrace LSM checks, plus `DAC_OVERRIDE` to get through the 0700 home directory. NFD offers no file/process feature source, so these path/process facts can't be expressed as rules — the detector is NFD's documented "external feature detector" extension point. Hardware scheduling stays with the generic-device-plugin (`infra.local/amd`, `infra.local/conbee`); NFD carries no hardware rules, though its built-in PCI/USB labels still show up incidentally. Because `external-exposed` tracks the live frpc process, a logtfy restart during an frpc outage sits Pending and schedules itself once frpc returns (running pods are never evicted — PV node affinity applies only at scheduling time). The NFD chart ships CRDs install-only (Helm `crds/`); no NFD CRs are managed. Removing the detector leaves its last feature file in place — delete it with `rm /etc/kubernetes/node-feature-discovery/features.d/node-facts`.
- **Jellyfin gets /dev/dri through the generic-device-plugin, not `privileged`** (`targets/srv0/k3s-apps/templates/jellyfin.yaml`) — it requests `infra.local/dri`, runs as `$MY_UID` under `container_t`, and needs no spc_t (renderD128 is 0666 and container_t can open it). The device cgroup grant is scoped to the render node. frigate and immich use the same grant (container_t + s0, pinned to srv0 — frigate retains CAP_PERFMON but its dashboard GPU-stats graph fails because SELinux denies container_t `perf_event_open`). The device plugin itself is unprivileged (spc_t, no capabilities); pvc-backup/restore pods are non-privileged (spc_t + DAC_OVERRIDE/FOWNER); ollama uses the `infra.local/amd` grant (kfd + dri on bigpc) with container_t + s0; mosquitto runs as uid 1883. On TCP 2049, nfs-server ingress is allowlisted to the node CIDR (every share is nfsvers=4.2 and CSI mounts originate on nodes); the CIDR is hardcoded as `192.168.8.0/24` in `nfs-server.yaml`, so change it for a different LAN.
- **nfs-server must stay `privileged`** (`targets/srv0/k3s-base/templates/nfs-server.yaml`) — it hosts a kernel NFS server (`nfsd`/`rpc.mountd`) inside the container, which privileged is genuinely required for. It's an internal base component with no ingress; don't suggest de-privileging.
- **vps0's `one_factor` Authelia rules are intentional** for ytdl/ikom/sale (family and guests); the admin catch-all is the only `two_factor` rule (TOTP is Authelia's default second factor, so no `default_second_factor_policy` is needed).
- **srv0's PROXY-protocol trustedIPs deliberately include the pod/service CIDRs** (`targets/srv0/k3s-base/templates/traefik.yaml`). frpc dials `127.0.0.1:8443`, but that port belongs to a host-network klipper-lb `svclb` pod forwarding to the Traefik Service, so kube-proxy SNAT makes the Traefik pod observe pod/service-CIDR sources; the PROXY v2 header (produced by vps0's Traefik `serversTransport frps-proxy` in the `traefik_dynamic` config) travels inside the tunnel stream. A source outside the trusted list would leave the header unparsed and break the TLS stream — narrowing the list below those CIDRs kills `home.*`. Accepted consequence: any pod can forge a PROXY header at the host port.
- **CrowdSec's `clientTrustedIPs` is a bypass-whitelist for clients, not an XFF/proxy knob** (the plugin README: "List of client IPs to trust, they will bypass any check from the bouncer or cache"). Proxy trust is `forwardedHeadersTrustedIPs`, which is `127.0.0.1/32` on both stacks; docker-network callers are exempted at the crowdsec layer by the `s01-whitelist` postoverflow, not `clientTrustedIPs`. Don't reintroduce it to "fix" internal traffic.
- **Agents must never read `config/` or anything in it** — those secrets are private by design; an audit verifies gitignore coverage and git history, never file contents.

## Manual first-time setup

One-time web-UI steps for apps with no API seeding:

- **radarr / sonarr** (`https://radarr.$SERVICES_DOMAIN`, `https://sonarr.$SERVICES_DOMAIN`, Authelia-protected): General → Authentication → Forms (create the admin account); Media Management → Root Folders (`/data/Movies` for radarr, `/data/TV` for sonarr); Download Clients → qBittorrent at `qbittorrent.apps.svc.cluster.local:8080` (credentials from the qBittorrent setup); Indexers via Prowlarr or manual; Connect → Jellyfin (`http://jellyfin.apps.svc.cluster.local:8096`, API key from the Jellyfin dashboard, notify On Import/On Upgrade). The arr API keys come pre-configured — read them with `kubectl -n apps get secret radarr-secret|sonarr-secret`.
- **prowlarr** (`https://prowlarr.$SERVICES_DOMAIN`): under Settings → Apps, register Radarr (`http://radarr.apps.svc.cluster.local:7878`) and Sonarr (`http://sonarr.apps.svc.cluster.local:8989`) using the keys from their secrets; Settings → Indexers then syncs both. Add FlareSolverr (`http://flaresolverr.apps.svc.cluster.local:8191`) for Cloudflare-protected indexers.
- **seerr** (`https://seerr.$SERVICES_DOMAIN`): log in with the Jellyfin account (`http://jellyfin.apps.svc.cluster.local:8096`), then under Settings → Services add Jellyfin, Radarr, and Sonarr (same URLs/keys as above).
- **Frigate ↔ Home Assistant**: add the MQTT integration once (`broker: mosquitto`, `port: 1883`, `user: homeassistant`, password = `HA_MQTT_PASSWORD` from VARS), then add the Frigate integration (`URL: http://frigate:5000`, the internal unauthenticated port). MQTT discovery creates the camera/event entities automatically, and the dashboard is provisioned for you (core cards only — no custom components; the Advanced Camera Card comes from the HA `integration-update` init container at `/local/community/advanced-camera-card-2026/dist/...`). Recordings go to NFS under `$SECONDARY_STORAGE_PATH/frigate`. Watch out: the Frigate UI can't be iframed (Authelia sends `X-Frame-Options: DENY`); the HA companion app can cache an old frontend (clear its storage); and deleting the rpi go2rtc password file means updating `FRIGATE_RTSP_PASSWORD` in VARS and re-applying frigate.
- **crowdsec-web-ui** (srv0 + vps0, once): register the LAPI machine using the `CROWDSEC_WEBUI_LAPI_PASSWORD` value, then create the first admin in the UI (`https://crowdsec.$SERVICES_DOMAIN` / `https://crowdsec.$CLOUD_SERVICES_DOMAIN`). On srv0, during an unlock: `kubectl -n base exec deploy/crowdsec-lapi -- cscli machines add crowdsec-web-ui --password '<value>' -f /dev/null`. On vps0: `docker exec crowdsec cscli machines add crowdsec-web-ui --password '<value>' -f /dev/null`. The registration lives in the LAPI DB (`crowdsec-pvc` / `compose_live_state/crowdsec/data`), and the app keeps retrying bootstrap in the background, so order doesn't matter.

## Updates (Renovate)

Renovate runs daily at 17:00 America/Toronto as the `renovate` K3s CronJob on srv0 (base, `targets/srv0/k3s-base/templates/renovate.yaml`) using the full `renovate/renovate` image (it ships the Go toolchain, so the gomod manager works). The pod mounts only two files from the synced repo (`{{ INFRA_ROOT }}/config/VARS.env` and `{{ INFRA_ROOT }}/.git/config`, read-only) to source `RENOVATE_GITHUB_TOKEN` (auto-rotates on sync) and to infer `RENOVATE_GIT_AUTHOR` — the identity must be set **repo-locally** (`git config user.name/user.email`), since a global-only `~/.gitconfig` is invisible to the pod, and a default Renovate author makes the next run treat its own branches as foreign (autoclose skipped, rebases blocked). Renovate clones from GitHub itself. `bash scripts/renovate.sh [--dry-run]` is the manual equivalent for other machines (needs Node/npm + `go` from prereqs; runs on the current machine and opens PRs directly on GitHub).

Every PR is manual: `git fetch origin pull/<n>/head:renovate/pr-<n>`, `git checkout renovate/pr-<n>`, run `bash scripts/validate.sh <target>`, merge locally, then `git push origin master`. Never merge in the platform UI — origin remains the source of truth. Renovate rebases its own open PRs and closes them automatically once `master` contains the change (on its next run).

**Automerge is off** — `automerge: false` globally in `renovate.json`, so every PR waits for a human (patch/minor and the grouped docker-digests batch included). Nothing gates on CI, and merging only deploys the next time the deploy commands run (`docker compose up -d` / `helm upgrade --install`).

**Watchtower vs Renovate** — only pc/bigpc run watchtower, and it updates any local container lacking `com.centurylinklabs.watchtower.enable=false` — effectively just compose `syncthing/syncthing` (left untagged; socket-proxy carries the false label). Renovate's docker-compose manager skips `syncthing/syncthing`, which leaves the srv0 K3s syncthing (pinned tag) under Renovate. Everything else belongs to Renovate (srv0/vps0/rpi run no watchtower). Watchtower's own image is digest-pinned by Renovate (`nickfedor/watchtower:latest`) because it never updates itself.

`renovate.json` (repo root): the built-in managers cover **kubernetes** (`managerFilePatterns: /^targets\/srv0\/k3s-(base|apps)\/.*\.ya?ml$/` — plain pod-spec images, hook Jobs, and vendored system-upgrade manifests), **docker-compose** (every compose image), **dockerfile** (the geoip base), and **gomod** (both `go.mod`s). Regex managers add: (1) k3s chart images (`valuesContent` repository/tag pairs and single-line refs; `currentDigest` is captured so pinned images refresh rather than re-pin), (2) HelmChart CR versions (`oci://` through the docker datasource, since the helm datasource can't do OCI, or `chart:`+`repo:`+`version:`), (3) K3s plan versions (`github-releases` on `k3s-io/k3s` with custom versioning), (4) Traefik plugin pins in `additionalArguments` (vps0 compose too), (5) immich-machine-learning (`github-releases`, `-openvino` suffix preserved), (6) the HA Frigate integration + Advanced Camera Card pins, (7) dotdc Grafana dashboard URLs in the k8s-monitoring values, (8) images embedded in `scripts/pvc.sh`, and (9) `HELM_VERSION` in `scripts/prereqs.sh`. The runner script, not the repo config, supplies global options (token, repo). packageRules: floating `latest|stable|release|alpine` tags (plus every untagged compose image, which effectively carries `:latest`) get pinned to digests and all pins/refreshes are grouped into one PR (prHourlyLimit 20); majors are blocked for `postgres`, `clickhouse/clickhouse-server`, `fedora`, and `helm/helm`; syncthing (compose side; watchtower owns it on pc/bigpc) and the frozen moving-sale image are disabled; immich's postgres image uses custom regex versioning (only same-shape `18-vectorchordX.Y.Z-pgvectorA.B.C` tags, with the postgres major locked via the compatibility group). Nothing else is annotated — Renovate's default update decision applies.

Artifacts built in-repo are handled manually: `targets/srv0/k3s-base/geoip-src/src/build.sh` builds/pushes the geoip image and re-pins its digest in `geoip.yaml` (run it after merging a go.mod bump; Renovate keeps tracking the digest for its PRs), and bumping `plugins/authelia-header-gate`'s gomod only edits `go.mod`/`go.sum` — you must run its `build.sh` and commit the rebuilt `files/plugin.wasm` + `files/traefik-plugin-config.yaml`.

Post-update: `git diff` → `bash scripts/validate.sh <target>` → deploy.

## Environment variables

Available to bash scripts: `$INFRA_ROOT` (repo root — self-computed by `scripts/common.sh` unless pre-set, so the in-cluster pods' values win), `$TARGET` (set by `require_target`/`require_target_host`), `$COMPOSE_STATE_DIR` (`current_target/compose_live_state`), `$PVC_BACKUP_DIR` (`k3s_state_backups`), `$MY_UID` (current UID, forced to 1000 when root).

## Rules

- **Provision nodes only via `k3s-server.sh`/`k3s-join.sh`** — no raw installers or ad-hoc joins; those scripts carry the installer and the secret handling. Dev-only lint (`yamllint`/`shellcheck`) changes nothing.
- **Get kubeconfig access through the unlock** — the admin kubeconfig remains root-only (0600); open a dev session with `kubeconfig-unlock.sh` and never restore group/world access or a permanent `KUBECONFIG`.
- Leave `current_target/` alone (runtime state).
- Keep secrets out of git (`config/`, `compose.private.yaml`, `targets/*/compose/.env` are ignored).
- Give new components NetworkPolicies, and set requests/limits from observed usage.
