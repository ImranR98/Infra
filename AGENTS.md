# AGENTS.md

Infra is an Ansible-driven IaC repo for a multi-machine homelab. Ansible is the orchestration CLI (`ansible-playbook` against `ansible/playbooks/`), and a few retained payload scripts run directly on their target (PVC backup/restore, node-IP update). Everything for a target lives in `targets/<t>/`; shared engine (playbooks, roles) sits in `ansible/`, secrets in the gitignored `secrets/`. No build step, no agent, no inventory: playbooks run with the implicit `localhost` host, and the target is **always explicit** — nothing derives it from the machine's hostname (`infra <t> <op>`, or `-e target=<t>` on raw playbooks). Ops divide into target-selecting ops (compose, validate, helm, pvc — they name a target) and machine-local ops (prereqs, renovate, preboot, wireguard, k3s provisioning — they act on the machine they run on and take no target). k3s applies go through plain Helm via the srv0 chart's own playbook, compose VARS are plain YAML in the gitignored `secrets/` dir, loaded natively via `include_vars` (validated by in-role asserts). K3s node provisioning uses the repo's own `k3s_install` role (official get.k3s.io installer). Audience assumed to know Docker/Compose, Kubernetes, Traefik, Ansible.

## Prerequisites

Bash 4+, Python 3, Docker Compose v2, kubectl (K3s targets), helm (srv0), yq, jq, curl, openssl, python3. Ansible core + the `ansible.posix`/`community.general` collections + the `githubixx.ansible_role_wireguard` role (all in `ansible/requirements.yaml`). Node.js/npm and `go` for local `renovate` runs (npx + gomod manager). Dev-only: `shellcheck`, `ansible-lint`, `yamllint`. Install everything: `ansible-playbook ansible/playbooks/prereqs.yaml` on the machine to prepare — if ansible-core itself is missing, bootstrap it first (`sudo dnf|apt install ansible-core`), then re-run; the playbook installs packages, the pinned helm binary, the official Docker bootstrap, and the collections/roles declaratively.

## Targets

`targets/` is authoritative — the list below is current but may drift.

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s control-plane + frpc Compose sidecar | Main home server, LUKS-encrypted root; most workloads |
| `vps0` | Compose | Public VPS: Traefik edge, FRP server (frps), web apps |
| `bigpc` | Compose + K3s agent | Desktop: Ollama on AMD RX 9070 (ROCm) via agent node; syncthing |
| `pc` | Compose | Desktop: socket-proxy, watchtower, syncthing |
| `rpi` | Compose | Pi 400 webcam → authenticated RTSP (go2rtc), consumed by Frigate on srv0 |

Each target dir: `VARS.template.yaml` (committed; documents every required variable + generation commands), optional `compose/` and/or `k3s/`, target root-level payloads (the srv0 `helm_apply.yaml` playbook + the retained `*.sh` scripts that must exist as files — e.g. the in-cluster pvc-backup CronJob calls `targets/srv0/pvc.sh` from a kubectl pod).
Notable per-target facts:
- **srv0** — `base` group: namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring, cdi-specs. `apps`: immich, logtfy, jellyfin, navidrome, mdscl, mosquitto, homeassistant, ollama, open-webui, nextcloud, freshrss, linkwarden, opodsync, dscpln, opencanary, flaresolverr, fmd, plik, syncthing, headlamp, frigate (see `templates/base/` + `templates/apps/`). Compose sidecar = frpc only. Ollama runs on the `bigpc` agent (RX 9070/ROCm); Open WebUI reaches it in-cluster only (no LAN exposure). Jellyfin/Immich ML/Frigate use srv0's Iris Xe iGPU; Frigate recordings stay on NFS deliberately so the pod can move nodes. Home Assistant integration auto-installs on every pod start (no HACS).
- **bigpc** — K3s agent labelled `has-amdgpu=true`, tainted `scheduling-discouraged` (PreferNoSchedule), no Longhorn replicas (`create-default-disk=false`); Compose: dockerproxy_priv, watchtower (syncthing only), syncthing (host net).
- **vps0** — Compose: frps, traefik, authelia + db, crowdsec, plausible (app/ClickHouse/Postgres/init), shlink + db + web UI, uptime-kuma, dozzle (container health/logs, read-only via the dockerproxy socket), metube, isbn-lookup, pixelntfy, logtfy, strelaysrv, owncast (+ owncast-auth), ikom, cct26, moving-sale, obtainium, socket proxies. No watchtower — all vps0 images are Renovate-owned (floating tags digest-pinned). Two domain zones: `$BASE_SERVICES_DOMAIN` (public) and `$CLOUD_SERVICES_DOMAIN` (Authelia-protected, e.g. `cloud.$BASE_SERVICES_DOMAIN`).
- **rpi** — go2rtc runs the official image untouched; a one-shot `go2rtc-init` service generates the stream password on first start and persists it in `current_target/compose_live_state/go2rtc/` (`password` file + `go2rtc.env` consumed via compose `env_file`); WebUI loopback-only.

## Essential commands

Target-selecting ops (compose, validate, helm, pvc) take an **explicit target** — nothing infers it from the machine's hostname. Compose ops additionally must run **on** the target machine (the compose role asserts `hostname == target` so a wrong-machine run fails loudly); validate can check any target's files from any checkout (`infra <t> validate`). Machine-local ops (prereqs, renovate, preboot, wireguard, k3s provisioning) act on the machine they run on and take no target. `./infra` (repo root, symlink once: `ln -s ~/Main/Infra/infra ~/bin/infra`) is the everyday entry point: it resolves the repo root, cd's there and execs `ansible-playbook`, so it works from any directory; raw `ansible-playbook` from the repo root is equivalent (the root `ansible.cfg` is auto-discovered — no `ANSIBLE_CONFIG` needed). Extra args after the op pass through unchanged (`-e`, `--check`, `--dry-run`, `--tags`). Become'd ops (compose, prereqs) get `-K` added automatically when sudo isn't passwordless.

```
# everyday ops (infra; <t> = the target — always explicit; full reference below):
infra <t> validate                                    # yq + compose config + (srv0) helm lint/template
infra <t> compose-install                             # validate VARS, render templates (jinja2), up -d (must run ON <t>)
infra srv0 compose-restart frpc                       # re-render, down+up one service
infra <t> compose-backup                              # [-e backup_remote=user@host:path]
infra srv0 helm base|apps                             # umbrella-chart upgrade --install (preview: --dry-run)
infra srv0 pvc backup --all -y                        # PVC backup (or: infra srv0 pvc backup <name>)
infra srv0 pvc restore --all -y                       # PVC restore (or: infra srv0 pvc restore <name>)
infra renovate [--dry-run]                            # machine-local: manual Renovate run (opens PRs on GitHub)
infra prereqs                                         # machine-local: install prerequisites
infra <playbook-name> ...                             # machine-local playbooks by basename: preboot -e preboot_module=frpc,
                                                      #   wireguard -e wireguard_conf_src=..., k3s-server, k3s-join, ...

# full reference (raw ansible-playbook from the repo root; target-selecting
# playbooks require -e target=<t>):
ansible-playbook ansible/playbooks/validate.yaml -e target=<t>             # yq + compose config + (srv0) helm lint/template
ansible-playbook ansible/playbooks/compose_install.yaml -e target=<t>      # validate VARS, render templates (jinja2), up -d [-K]
ansible-playbook ansible/playbooks/compose_restart.yaml -e target=<t> -e compose_service=frpc   # re-render, down+up one service [-K]
ansible-playbook ansible/playbooks/compose_backup_state.yaml -e target=<t> # [-e backup_remote=user@host:path] [-K]
ansible-playbook ansible/playbooks/prereqs.yaml                       # machine-local: install prerequisites
ansible-playbook ansible/playbooks/renovate.yaml [-e renovate_args="--dry-run"]   # machine-local
ansible-playbook ansible/playbooks/wireguard.yaml -e wireguard_conf_src=$(readlink -f wg.conf)   # machine-local
ansible-playbook ansible/playbooks/preboot.yaml                       # machine-local: initramfs LUKS unlock (frpc tunnel / crypt-ssh)
ansible-playbook ansible/playbooks/k3s_server.yaml                    # machine-local: bootstrap control plane (no args; run ON the node)
ansible-playbook ansible/playbooks/k3s_join.yaml -e node_ip=.. -e node_user=..   [-e k3s_role=agent|server] [-e k3s_amdgpu_mode=auto|yes|no] [-e k3s_scheduling_discouraged=true] [-e k3s_longhorn_replicas=true]   # machine-local (run on the control plane); prompts for the control-plane + joining-node sudo passwords (may differ; no -K)

# srv0 target ops (retained payload scripts — run directly on srv0):
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=base|apps   [-e helm_args="--dry-run"] [-e helm_state=absent]    # umbrella-chart upgrade --install / uninstall
bash targets/srv0/pvc.sh backup --all -y            # PVC backup (or: pvc.sh backup <name>)
bash targets/srv0/pvc.sh restore --all -y           # PVC restore (or: pvc.sh restore <name>)
sudo bash targets/srv0/update-node-ip.sh [--ip X] [--force]   # K3s node IP change
```

The compose role asserts `hostname == target` so an explicitly-wrong-target run fails loudly (the retained scripts warn instead). Non-interactive PVC confirmations: pass `-y` to the script. Dev-only checks: `shellcheck $(find scripts targets -name '*.sh' -not -path '*/plugins/*')`, `ansible-lint -c ansible/.ansible-lint --offline ansible`, `yamllint -c ansible/.yamllint ansible`.

Ad-hoc diagnostics (no dedicated commands; run on the srv0 control plane):
- Mount a PVC + hostPath in a throwaway pod and shell into it:
  `kubectl run pvc-shell --rm -it --restart=Never -n <ns> --image=ubuntu:24.04 --overrides='{"spec":{"containers":[{"name":"s","image":"ubuntu:24.04","stdin":true,"tty":true,"command":["bash"],"volumeMounts":[{"name":"pvc","mountPath":"/pvc"},{"name":"host","mountPath":"/host"}]}],"volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"<pvc>"}},{"name":"host","hostPath":{"path":"/tmp/pvc-transfer"}}]}}'`
- NFS write/read smoke test against the shared RWX backup PVC (`pvc-backup-dest` in `base`):
  `kubectl run storage-test --rm -i --restart=Never -n base --image=busybox:1.36 --overrides='{"spec":{"containers":[{"name":"t","image":"busybox:1.36","command":["sh","-c","echo ok > /mnt/t && cat /mnt/t && rm /mnt/t"],"volumeMounts":[{"name":"d","mountPath":"/mnt"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"pvc-backup-dest"}}]}}'`

## Dispatch system

**Ansible is the only CLI** (plus a few retained scripts that run directly on their target — see above), fronted by the `infra` wrapper (repo root) for everyday ops. `ansible/playbooks/` holds the ops: target-selecting (compose, validate — they take `-e target=<t>`, never inferred) and machine-local (prereqs, renovate, preboot, wireguard, k3s provisioning — they run on the machine you are on, implicit `localhost`, no target). Target-root playbooks (`targets/<t>/*.yaml`, e.g. `targets/srv0/k3s/helm_apply.yaml`) hold the target-specific ops. The compose role asserts `hostname == target` so a wrong-machine run fails loudly. K3s node joins (`k3s_join.yaml`) build their node host at runtime with `add_host` — no inventory anywhere, for anything. The repo-root `ansible.cfg` (roles_path is config-relative, pointing at `./ansible/roles`) is auto-discovered from the repo root, so plain `ansible-playbook ...` works there without env vars; `infra` cd's there for you from any CWD.

Retained bash scripts (`scripts/common.sh` bootstrap: state dirs, `MY_UID`, `_confirm`, hostname warning; `targets/<t>/` payloads) exist only where something must run **as a file**: the in-cluster `pvc-backup` CronJob runs `targets/srv0/pvc.sh backup --all -y` from a kubectl pod (no ansible there), the node-IP update stays bash (`targets/srv0/update-node-ip.sh` — a native Ansible port of the etcdctl dance would be larger and riskier), and `scripts/renovate.sh` is the runner invoked by `renovate.yaml`. Compose VARS live as plain gitignored YAML (`secrets/VARS.<t>.yaml`, no encryption) and are loaded natively by the compose role via `include_vars` (flat, for jinja templates, and named `secret_vars`, for the compose interpolation env — see the shared `roles/compose/tasks/vars.yaml`) when the target has a `VARS.template.yaml` (srv0, vps0).

### Writing a new playbook or script

New target-selecting logic belongs in `ansible/` (role + playbook on `hosts: localhost` requiring `-e target=<t>` — no hostname default) or at the target root (`targets/<t>/foo.yaml`, `hosts: localhost` + the hostname assert) when it serves a single target. Machine-local logic (preboot-style, acting on the machine itself) takes no target. Any playbook in `ansible/playbooks/` is reachable as `infra <basename>` (machine-local) and target ops as `infra <t> <op>` with no extra wiring — add a named `infra` case arm only for ops needing argument sugar. A retained bash script goes to `targets/<t>/` (or `scripts/` when truly universal, like `renovate.sh`) with a `# DESC:` second line, sourcing `$INFRA_ROOT/scripts/common.sh`. Useful helpers in `scripts/common.sh`: `_confirm`, `get_sudo_cmd`, `wait_for_k3s_cluster`, `get_node_ip`.

### Comment & doc guidelines

- Comments explain current behavior and non-obvious WHYs only — never history ("used to", "previously", "replaces the old X", "deleted"); past designs live in git history.
- Keep comments minimal: file headers say what the file IS; don't restate the code or narrate steps.
- No device names (srv0/vps0/bigpc/pc/rpi) in shared code (`ansible/`, `scripts/`) — shared logic must stay generic (e.g. "the frpc variant renders the compose templates first", not "srv0 renders first"). Per-device facts live in `targets/<t>/`; README.md and AGENTS.md are the only shared files that may name targets.
- Docs describe the current codebase only — migration guides and historical notes are deleted once the migration lands.
- After editing, scan for this pattern: `grep -rniE 'the old|previously|formerly|replaces the old|is gone' ansible scripts targets` should return nothing but legitimate current-behavior notes.

## Variables & templating

- **One VARS file per target**: `secrets/VARS.<t>.yaml` — plain YAML (gitignored; no encryption), loaded by the compose role via `include_vars` and — for srv0 — passed to Helm as the umbrella chart's values file (`helm_apply` uses `-f values.yaml -f secrets/VARS.srv0.yaml`; the committed `values.yaml` only holds the release gates + `MY_UID`). `targets/<t>/VARS.template.yaml` documents every key + generation command. srv0/vps0 have VARS files (srv0's feeds both compose + k3s); bigpc/pc/rpi are builtin-var-only.
- **Compose VARS pipeline**: `secrets/VARS.<t>.yaml` (plain YAML map) is loaded by the compose role via `include_vars` — once flat (keys become jinja template variables) and once as `secret_vars` (the dict for **docker-compose native interpolation**, stringified into `compose_env`). No expansion step: values are final. Completeness is asserted against the template keys and placeholder values (`change_me`/`changeme`/`abc`/`REPLACE_ME`/`<...>`) are rejected — assert messages print key names only. `docker compose` interpolates `$VAR`/`${VAR}` in `compose.yaml`/`compose.private.yaml` natively — no envsubst, no merged render file; `-f` merge is native compose.
- **No encryption** — the VARS files are plain YAML at rest (gitignored under `secrets/`); there is no ansible-vault and no `.vault_pass`. Create them by copying the template and filling every value literally (`${NAME}` references do not expand).
- **Format** — YAML map `KEY: value`. Multi-line values are literal block scalars (`|`) — indentation is data and splices are verbatim (the vps0 geoblock subset is the one `indent(10, true)`-spliced exception). A bare `$` and `#` are literal — write `$argon2id$...` unescaped. Inline comments (` # ...`) work after single-line values.
- **Universal VARS** — target-agnostic secrets live in `secrets/VARS.env` (fallback: root `VARS.env`), dotenv format. Loaded on demand by the commands that need them (`renovate` requires `RENOVATE_GITHUB_TOKEN`; the in-cluster renovate CronJob does `set -a; . /repo/secrets/VARS.env`). Not template-validated — each command checks its own variables.
- **Validation** — VARS asserts in the compose role + `validate.yaml` print variable names only (**values never reach argv, stdout, or stderr**). `validate.yaml` additionally checks YAML syntax, the rendered helm chart (missing values surface as `<no value>` render failures), `docker compose config`, and placeholder patterns in `secrets/values.<target>.yaml`.
- **Multi-line vars** (Authelia user DB, JWKS, frigate config, geoblock subset, mTLS PEMs): in the VARS YAML they are block scalars that jinja2 splices verbatim and Helm splices via `{{ .Values.X | indent "N" }}` (the vps0 geoblock subset is the one `indent(10, true)`-spliced compose exception).
- **Structural `$VARIABLE` placeholders** — a bare `$VAR` line at mapping indent in a compose file is invalid YAML before interpolation; `validate` detects this and downgrades the syntax error to a warning.
- **mTLS certs** — generated with documented copy-paste `openssl` commands in the FRP sections of both `VARS.template.yaml` files (per-pair CA, server/client certs, preboot client cert); PEMs live as multi-line VARS values.
- **`*_HASHED` (k3s authelia)** — precomputed hashes stored in the same VARS file next to their `*_HASHABLE` plaintexts (`openssl passwd -6` or `authelia crypto hash generate pbkdf2`; the generation commands are in `VARS.template.yaml`).
- `PROXY_IP` is resolved from `PROXY_HOST` by the compose role (`getent hosts`) at render time.

### Compose pipeline (Ansible)

- `ansible/roles/compose/` + `compose_install.yaml` / `compose_restart.yaml` / `compose_backup_state.yaml` own the compose pipeline.
- Templates: `compose/templates/**` → `$COMPOSE_STATE_DIR/` via `with_filetree`. `.secret` → jinja2 render + mode 0600 (`no_log`), `.plain` → verbatim copy, everything else → jinja2 render; parent dirs are created by the role. (Authelia `users_database.yml` is a `.secret` template splicing `AUTHELIA_USERS_DATABASE`; traefik `acme.json` seeding is a `copy force: false` task.)
- `compose install` — renders templates, resolves host bind dirs from `docker compose config` itself (the compose file is the single source of truth; a dot in the final path component means a file bind — create its parent) with `$MY_UID` ownership, then `docker compose -p $TARGET -f compose.yaml [-f compose.private.yaml] up -d --remove-orphans` with the interpolated environment. Project name = target. Reboot survival = per-service `restart:` policies (no systemd wrapper).
- `compose backup-state` — local: tars `$COMPOSE_STATE_DIR` via an Alpine container (skips FIFOs/sockets) and prunes to `$BACKUP_RETENTION` (default 1). Remote: `-e backup_remote=user@host:path` streams the tar back over SSH into `compose_state_backups/` (the remote runs docker directly — no task/ansible needed there).

## K3s conventions

Components live in the srv0 umbrella chart (`targets/srv0/k3s/`, the chart root itself):
- `templates/base/` + `templates/apps/` — one file per component, native Helm templates (`{{ .Values.X }}` refs; secrets/config come from `secrets/VARS.srv0.yaml`), gated by `{{ if .Values.base.enabled }}` / `{{ if .Values.apps.enabled }}`. Secrets/configmaps live in `prereqs` sections of the component files, next to their Traefik `IngressRoute`s and `NetworkPolicy`s.
- `templates/hooks.yaml` — one seeding Job (`immich-seed`) as a Helm `post-install,post-upgrade` hook with `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`; RBAC via the `helm-hooks` ServiceAccount/Role. Other first-boot seeding is declarative: qBittorrent via a `qBittorrent.conf` ConfigMap + copy-once initContainer in `apps/qbittorrent.yaml`, the GeoLite2 DB via the geoip Deployment's `geoipupdate` initContainer (weekly CronJob keeps it current).

**Apply pipeline** — `targets/srv0/helm_apply.yaml` runs `helm upgrade --install` with `-f values.yaml -f secrets/VARS.srv0.yaml` (the same VARS file the compose sidecar uses). Two releases: `srv0-base` (scope base, `--set apps.enabled=false`) and `srv0-apps` (inverse); `base.enabled`/`apps.enabled` gate both the templates and the seeded Jobs. Preflights (apply only): the secret values file must exist and contain no placeholders, and the rendered chart must contain no `<no value>` (helm silently renders missing keys); `helm_state=absent` uninstalls instead. The chart contains: (a) all repo-owned components as Helm templates (secrets, configmaps, ingresses, PVCs, cronjobs, the traefik Middlewares/HelmChartConfig + WASM plugin ConfigMap via `.Files.Get`), (b) the 18 upstream-app **HelmChart CRs** — helm-controller still owns the app releases exactly as before (avoids release-name-derived resource naming), (c) vendored system-upgrade-controller manifests + Plans, (d) the immich seeding hook as a `post-install,post-upgrade` Job with scoped RBAC under the `helm-hooks` ServiceAccount.

Ops: `helm list/history/rollback`, `helm get values`, `helm template`, `helm diff upgrade` (helm-diff plugin); delete = `helm uninstall srv0-apps` then `srv0-base` (Helm retains PVCs).

**Authelia header gate (srv0)** — `AUTHELIA_HEADER_GATE_ENABLED` is a VARS knob (default `"false"` → pass-through); on a fresh bootstrap set it `"true"` until Authelia is Ready, then back to `"false"`. The local WASM plugin `authelia-header-gate` (TinyGo, loaded via `--experimental.localplugins`, shipped in the `traefik-local-plugins` ConfigMap) then returns 401 for any request lacking a `Remote-User` header; its `blocking` field comes from the VARS value. Once Authelia exists, re-applies use the VARS value (default `"false"` → pass-through). Publicly-bypass services use the `authelia-with-optional-header-gate` chain (Authelia bypass + gate). vps0 doesn't use the gate.

**Groups** — apply both scopes in order (`base` then `apps`); delete in reverse (`srv0-apps` then `srv0-base`). Helm retains PVCs on uninstall.

**Node commands (Ansible-provisioned — `ansible/`)**

Node provisioning is owned by the repo's `k3s_install` role (the official `get.k3s.io` installer — no provisioning collection). Provisioning uses **no inventory file**: `k3s_join.yaml` builds its node host at runtime via `add_host` from extra vars, so any node can become the control plane and any node can join in any role at runtime — no host metadata in the repo. Cluster policy defaults live in the playbooks + the shared `playbooks/vars/k3s.yaml` (server-config baseline) + `k3s_node_extra` role defaults; per-run values are extra vars from the CLI.

- `k3s_server.yaml` (no args, run ON the node): `connection=local`; `k3s_install` writes `k3s_server_config` (the `vars/k3s.yaml` baseline + `cluster-init: true`, `node-ip`, labels `hostpath-main=true`, `hostpath-extra-storage=true`, `external-exposed=true`) to `/etc/rancher/k3s/config.yaml` and restarts the k3s service; `k3s_node_extra` adds the containerd CDI drop-in (`enable-cdi.toml` — enables CDI so the `cdi-specs` component can grant host devices), the `kubectl` group, firewall (firewalld/ufw; K3s ports incl. 51820–21/udp for flannel-wg) and sysctls (inotify, user namespaces); then `k3s_configure` labels the node for Longhorn default disk + `has-homeassistant-hardware`. K3s needs a fixed IP — if it changes, run `targets/srv0/update-node-ip.sh`.
- `k3s_join.yaml` (`-e node_ip=.. -e node_user=.. [-e k3s_role=agent|server] [-e k3s_amdgpu_mode=auto|yes|no] [-e k3s_scheduling_discouraged=true] [-e k3s_longhorn_replicas=true]`, run ON the control plane; prompts for the control-plane and joining-node sudo passwords separately — they may differ, no `-K`): play 1 reads the token from `/var/lib/rancher/k3s/server/token` (slurp, `no_log`) and resolves the server IP; play 2 runs `k3s_node_extra` + `k3s_install` on the node over ssh (`k3s_mode: agent` — the token lands in the node's root-only `k3s-agent.service.env` — or `k3s_mode: joined_server` with a `server:` URL + token in `config.yaml`); play 3 waits for the node to appear + become Ready, then `k3s_configure`. The token reaches the node as an inventory variable (`no_log` both ends; the standard k3s agent pattern). All join options are CLI flags. AMD GPU detection is `lspci`-based (vendor `1002`, VGA class; `--amdgpu yes|no` forces, default `auto`) and applies the `has-amdgpu=true` label (drives ROCm/Ollama scheduling). Longhorn flag: `create-default-disk=true` + auto-increment `default-replica-count` (guarded by the label task's `changed`, so re-runs don't double-count); without the flag → `create-default-disk=false`.
Dev-only (no hosts touched, no inventory required): `ansible-playbook --syntax-check` on all playbooks, `yamllint -c ansible/.yamllint ansible`, `ansible-lint -c ansible/.ansible-lint --offline ansible`. `targets/srv0/update-node-ip.sh` (retained bash, run directly on srv0): sed-replaces `node-ip` in drop-ins, adds `50-node-ip.yaml`; **updates etcd member peer URLs before restarting k3s** (k3s is `Type=notify`; a synchronous restart deadlocks), restarts with `--no-block`, patches the node's flannel public-ip annotation + status addresses. Installs etcdctl on demand. Kept as bash deliberately: a native Ansible port of the etcdctl dance would be larger and riskier than the script it replaces.

Roles: `k3s_install` (installer via `get.k3s.io` — fetched over TLS with no local hash cross-check, same trust model as running the official installer by hand; writes config.yaml, the agent token env file, restarts the systemd service), `k3s_node_extra` (sysctls, CDI drop-in, firewall ports/trusted CIDRs, kubectl group, pciutils for AMD detection), `k3s_configure` (labels/taint/Longhorn via kubectl, `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`). `k3s_install` only (re)runs the installer when the installed version is older than `k3s_version` (`stable`) — re-running provision never re-runs the installer, so it can't fight system-upgrade-controller's version ownership. `--check`/`--diff` dry-runs work for everything except the installer execution itself. Prereq: `ansible-playbook ansible/playbooks/prereqs.yaml` (ansible-core via the package manager first if missing); pciutils is auto-installed on agents. SSH host-key checking is left at Ansible's default (on) — the first join prompts to accept the fingerprint, same trust model as plain `ssh`. Dry-run on a test VM (Multipass): launch a fresh VM, copy the repo in, run the prereqs playbook, then `k3s_server.yaml --check --diff` before the real run.

**system-upgrade** — system-upgrade-controller manifests are **vendored** in `templates/base/system-upgrade-controller.yaml` (downloaded from `releases/latest` of rancher/system-upgrade-controller at cutover; bump by re-downloading `crd.yaml` + `system-upgrade-controller.yaml` and replacing the template — the controller image inside is Renovate-managed via the kubernetes manager). `server-plan`/`agent-plan` versions are Renovate-managed (`vX.Y.Z+k3sN`, matched in the templates by the plan-version regex manager). After a bump: `ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=base`, then `kubectl -n system-upgrade get plans,jobs`.

**valuesSecrets** (k3s helm-controller) — HelmChart CRs can pull values from a namespaced Secret: `spec.valuesSecrets: [{name, keys}]`; each listed key is projected as a `values-0-00N-HelmChart-ValuesSecret.yaml` file merged after `valuesContent` (plain Helm deep-merge, later file wins; `keys` must be non-empty). Used by frigate + loki (see Security); changes to the Secret re-trigger the chart upgrade (`ignoreUpdates: false` default). The referenced Secret must live in the CR's namespace and not be named `chart-values-<chart>`.

## Helm crash course (as used in this repo)

**Mental model.** Helm is a package manager that turns a *chart* (templates + values) into Kubernetes manifests and tracks the result as a *release*. Helm is **client-only** — nothing runs in the cluster; the `helm` binary (installed by the prereqs playbook, version-pinned) does everything from wherever you run it. Each install/upgrade stores the full rendered manifest as a revision (in `sh.helm.release.v1.<name>.v<n>` Secrets). `helm upgrade --install` is idempotent: it three-way-merges the new render against the *last stored* manifest and patches only what changed — re-running the helm_apply playbook with no file changes touches nothing and just bumps the revision counter.

**Three layers of "helm" in this repo — do not conflate them:**
1. **Our umbrella chart** (`targets/srv0/k3s/`, the chart root) → releases `srv0-base` + `srv0-apps`, applied by `targets/srv0/helm_apply.yaml`.
2. **k3s's embedded helm-controller** → the 19 `HelmChart` CRs *inside* our chart. Our releases apply the CR objects; the controller then installs/upgrades the app releases (frigate, immich, …). `helm uninstall srv0-*` does NOT touch these; `kubectl delete helmchart` triggers THEIR uninstall (see cutover mechanics above).
3. **k3s bootstrap charts** (traefik + traefik-crd in kube-system) — not ours at all; we only customize traefik via the `HelmChartConfig` template.

**Chart layout** (chart root = `targets/srv0/k3s/`):
- `Chart.yaml` — name/version only (no dependencies in this chart).
- `values.yaml` — committed defaults; just the `base.enabled`/`apps.enabled` gates.
- `templates/` — one file per former component, each wrapped in `{{ if .Values.base.enabled }}`/`{{ if .Values.apps.enabled }}`. Content is **native Helm templates** (`{{ .Values.X }}`; multi-line values splice via `| indent "N"`).
- `files/` — raw files shipped inside the chart, referenced from templates via `.Files.Get "files/<name>"` (**paths are chart-root-relative — the `files/` prefix is mandatory**; omitting it silently renders empty, which is how the WASM plugin broke).
- `templates/hooks.yaml` — Helm **hooks**: Jobs annotated `helm.sh/hook: post-install,post-upgrade` run automatically after every install/upgrade, retried via Job backoff, deleted on success (`helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`).

**Everyday commands:**
```
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=base    # upgrade --install srv0-base, idempotent
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=apps
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=base -e helm_args="--dry-run"   # preview
helm ls -A                                # releases + revision + status
helm history srv0-base -n base            # revision log
helm rollback srv0-base <rev> -n base     # instant rollback to an earlier revision
helm get values srv0-base -n base         # effective values
helm status srv0-base -n base
helm template srv0-base targets/srv0/k3s -n base -f values.yaml -f ../../secrets/VARS.srv0.yaml --set apps.enabled=false   # dry render
helm diff upgrade srv0-base targets/srv0/k3s --set apps.enabled=false       # preview (helm-diff plugin)
helm uninstall srv0-apps -n apps          # delete a release; PVCs are retained by Helm default
```

**Pitfalls learned the hard way:**
- `helm lint`/`helm template` need the values files (`-f values.yaml -f secrets/VARS.srv0.yaml`) — without them, `.Values.X` is nil and lint fails with 'invalid value; expected string'. Missing keys render as `<no value>` — the validate playbook and helm_apply's preflight catch that.
- `.Files.Get` paths need the `files/` prefix (see above).
- Literal `{{` in templates is interpreted by helm — the homeassistant CR's embedded Go templates are escaped as `{{ "{{" }}`.
- Subchart resource names derive from `{{ .Release.Name }}` — that's why the app charts stay HelmChart CRs (helm-controller-managed) instead of umbrella dependencies.
- Never `helm install --force` casually — it deletes/recreates resources; one accidental `--force` during the cutover re-released 4 HelmChart CRs.
- `kubectl apply --dry-run=server` on rendered output gives false positives (e.g. the 256KiB `last-applied-configuration` limit that doesn't apply to Helm's merge) — use helm's own `--dry-run=server`.
- Adoption: pre-existing objects must carry `app.kubernetes.io/managed-by: Helm` + `meta.helm.sh/release-name`/`release-namespace` annotations or helm refuses to install over them (see cutover mechanics above).
- Helm uninstall ignores live-object annotations entirely — `helm.sh/resource-policy: keep` only works from the *stored* manifest.
- Helm doesn't auto-resolve k3s's kubeconfig the way k3s's kubectl does — helm_apply sets `KUBECONFIG` to `/etc/rancher/k3s/k3s.yaml` when the env var is unset.

## Storage & PVC backups

- **Longhorn** is the default StorageClass and primary backend (replica count 1, best-effort locality, 2000% over-provisioning; chart version has `# PRESERVE_FULL` — sequential minor upgrades required). NFS (`nfs-server` + `csi-driver-nfs`) and static hostPath PV/PVC pairs (`host-volumes`, RWX, bound to `hostpath-main`/`hostpath-extra-storage` nodes) remain for shared host data.
- **Backup** — `pvc-backup` (base group) is a nightly 3AM CronJob that runs `targets/srv0/pvc.sh backup --all -y` in-cluster (bitnami/kubectl:latest, hostPath mounts of `$INFRA_ROOT` + `$PVC_BACKUP_DIR`, nodeSelector `hostpath-main`). PVCs labelled `auto-backup: "true"` are archived; annotation `backup.infra/exclude` adds tar `--exclude` patterns. A temp pod (scheduled on the volume's node for RWO; tolerates `scheduling-discouraged`) tars the live PVC (no scale-down) to the shared `pvc-backup-dest` PVC — a static PV bound to the ROOT of the NFS backups share (= `$PVC_BACKUP_DIR`), so archives land directly at their final human-named path `<name>.tar.gz` (with `__backup_timestamp.txt` inside), overwritten each run, reachable from any node.
- **Restore** — scales down all workloads using the PVC (Deployments/StatefulSets only; replica counts recorded), waits for pods, restores via a privileged temp pod, scales back up. `--all` does a bulk scale-down of everything first.
- Both backup and restore pods set **pod-level** `seLinuxOptions.level: s0` (see SELinux below).

## Networking

- **Traefik on srv0** — dual entrypoints: `websecure:443` (LAN, no proxy protocol) and `websecure-proxy:8443` (PROXY protocol v2, trustedIPs `127.0.0.1/32` + pod/service CIDRs — Klipper SNAT makes all traffic appear from those). Public routes listen on both; LAN-only (`*.home.local`) routes only on `websecure`. Middlewares: `geoblock` (allowlist plugin, self-hosted MaxMind GeoLite2 via the `geoip` component's `geoip-service`), `crowdsec-bouncer` (stream mode + AppSec on `:7422`), `forwardauth-authelia`, `lan-whitelist` (RFC1918), `cluster-only` (10.42/16), `basicauth-cluster`, `local-no-store`. HTTP → HTTPS redirect. readTimeout=0 on both secure entrypoints (streaming). Plugins are pinned in `additionalArguments` (regex-managed via `github-releases`).
- **vps0 edge** — one Traefik routes by Host/SNI: vps0-local services via Docker labels (two zones, see Targets); `home.$SERVICES_DOMAIN` + wildcard goes through the file provider (`dynamic-configuration.yaml`) to `frps:8080` (HTTP) / `frps:8443` with `tls.passthrough` — vps0 never terminates srv0's TLS; cert-manager on srv0 owns the LE lifecycle. On srv0, cert-manager also runs a local chain (self-signed → `k3s-local-ca` → `ca-issuer`) for `*.home.local`/MQTT TLS; its `post.sh` waits for each chain step before proceeding (race-condition guard).
- **FRP** — frps on vps0 (ports: 7000 control, 8887 preboot SSH, 8888 SSH; healthcheck on admin API :7500). frpc sidecar on srv0 (host network, `pgrep` healthcheck) proxies: ssh→8888, http→8080, https→8443 (local), qbittorrent peer 56881 tcp+udp. Mutual TLS with a per-pair CA (generated via the documented openssl commands in `VARS.template.yaml`); preboot frpc uses a separate client cert.
- **WireGuard** (`wireguard` command, Ansible playbook `wireguard.yaml` `connection=local`) — deploys a provider `wg0.conf` via the `githubixx.ansible_role_wireguard` community role. The playbook parses the provider conf into role vars (PrivateKey/Address/DNS/MTU/PresharedKey/Endpoint — values never echoed), rewrites `AllowedIPs` to `0.0.0.0/1, 128.0.0.0/1` (split-tunnel: less specific than LAN routes, so K3s subnets and LAN stay direct), and adds PostUp/PreDown `/32` routes for the endpoint via the physical gateway (dead-loop fix) through the role's `wireguard_postup`/`wireguard_predown`. The role owns package install, the 0600 conf, and the `wg-quick@wg0` systemd unit (config changes apply via `wg syncconf`).
- **LUKS preboot** — `ansible/playbooks/preboot.yaml`, run on the node (shared `preboot` role; `-e preboot_module=frpc|crypt-ssh`). srv0 (frpc): the frpc compose templates are rendered first (mTLS certs), then initramfs frpc tunnels SSH via FRPS on port 8887. bigpc (crypt-ssh): dropbear patched to preboot_port for direct LAN unlock (ethernet only). After rotating preboot mTLS certs, re-run the playbook on srv0. When adding initramfs networking, verify with `lsinitrd` that firmware actually made it in (drivers don't retry firmware loads after pivot_root).

## Security

- Secrets never touch git (`/secrets/`, `/VARS*.env`, `compose.private.yaml` gitignored); `.secret` → chmod 600; Authelia SSO (forward-auth + basic-auth, 2FA); CrowdSec (srv0: Helm chart, agent/LAPI/AppSec + per-service postoverflow whitelists; vps0: single container, bouncer key auto-registered from `BOUNCER_KEY_TRAEFIK`); geoblock allowlist (CA/CN/CU); per-component NetworkPolicies plus baselines in the `namespaces` component (kube-system policy explicitly allows 80/443/8000/8443 to Traefik).
- Docker socket via `wollomatic/socket-proxy`: `dockerproxy` (read-only, Traefik/monitoring); `dockerproxy_priv` (read-write, watchtower) exists only on pc/bigpc — `cap_drop: ALL`, `read_only: true`, `mem_limit: 512M`, user `65534:$DOCKER_GID`.
- Known tradeoff: K3s `HelmChart` `valuesContent` (incl. DB passwords, JWKS, OIDC secrets) is readable by anyone with `get` on `helmcharts.helm.cattle.io` — fine for single-user, audit before granting namespace access. Reduced where charts support it: authelia (secret `path:` refs), crowdsec (`externalSecret`), grafana (`admin.existingSecret`), headlamp (`oidc.externalSecret`), rustfs (`secret.existingSecret`), immich/nextcloud/plik (plain-YAML `secretKeyRef`). Where the chart has no secret-ref support but the value is plain YAML, the component uses **`spec.valuesSecrets`** (k3s helm-controller): the secret values live in a namespaced Secret (now `targets/srv0/k3s/templates/apps/frigate.yaml` + `templates/base/monitoring.yaml`, key `values.yaml`) listed in the CR via `valuesSecrets: [{name, keys}]` — the controller projects it as a later `-f` values file, so the merge is plain Helm deep-merge and renders identically. Done this way: **frigate**'s `env` passwords (its `env` key only accepts plain strings — chart limitation) and **loki**'s S3 keys (the 7.x chart's config handling makes `existingSecretForConfig` too risky; the values merge sidesteps the chart). Remaining unavoidable plaintext: authelia's JWKS PEM (`value:` embedded — the chart generates a RANDOM key if the `CryptographicKey` secret isn't inline; verified the hard way). Also: freshrss stays a root container (official image hardcodes apache on :80 and its entrypoint runs as root — de-rooting needs a custom apache config); nextcloud stays a root container too (verified: the official entrypoint writes /etc/apache2 as root even with APACHE_PORT set — uid 33 crashes on `remoteip.conf` removal; the PVC is already www-data-owned so this is purely an entrypoint limitation).
- **SELinux (Fedora nodes)** — Kubernetes assigns per-pod MCS categories; files carry their creator's categories forever. Pods sharing a hostPath tree (syncthing/mdscl/dscpln) and backup/restore pods must set **pod-level** `seLinuxOptions.level: s0` (container-level is ignored). `privileged: true` bypasses enforcement but new files are still labelled. Python/Node `io_uring` denials are audit spam with epoll fallback — fix with `PYTHON_IO_URING=0` / `UV_USE_IO_URING=0` rather than SELinux changes. `setroubleshootd` CPU pegged = denial backlog; fix the denials, don't mask.

### Accepted Security Tradeoffs

Accepted tradeoffs and resolved audit findings — do not re-flag without reading the referenced reasoning:

- **`adminadmin` qBittorrent password is accepted** (`targets/srv0/k3s/qbittorrent/post.sh`) — the web UI sits behind forwardauth-authelia + geoblock + crowdsec; the password is an internal convenience, not a security boundary. Never propose "fixing" it.
- **NetworkPolicies ARE enforced** — K3s ships an embedded network-policy controller (kube-router) enabled by default; this repo never sets `--disable-network-policy` (the playbooks set `flannel-backend: wireguard-native` only). Flannel being the data path does NOT mean policies are unenforced. Verify with `kubectl -n kube-system get pods | grep -i router` before claiming otherwise.
- **The authelia-header-gate is NOT forgeable** — in the `authelia-with-optional-header-gate` chain (`targets/srv0/k3s/traefik/middlewares.yaml`), `forwardauth-authelia` runs FIRST and, on any 2xx auth response, deletes client-supplied `Remote-User` and re-adds it only if Authelia's verify response contained it (Traefik v3 `pkg/middlewares/auth/forward.go`). `bypass` responses carry no `Remote-User`, so a forged header is stripped → the gate 401s. When Authelia is unreachable, forwardauth aborts the chain (500) before the gate runs. The only way `Remote-User` reaches the gate is genuine Authelia authentication. Do not re-flag the gate without reading the chain order.
- **SSH hardening is out of repo scope** — sshd/fail2ban hardening is done manually on the machines, pre-repo. Don't propose `harden-ssh`-style commands. The open SSH tunnel at vps0:8888 is mitigated by pubkey-only auth set up out-of-band.
- **Unpinned supply-chain fetches are accepted tradeoffs** — the dracut clone in `preboot.yaml`, the etcdctl "latest" download in `update-node-ip`, `releases/latest` system-upgrade manifests, the TOFU K3s installer fetch (`get.k3s.io` over TLS, no local hash cross-check), and `get.docker.com` in `prereqs` (apt/dnf paths) are all deliberate: pinning them costs manual version bumps. Do not propose pinning.
- **vps0 `s01-whitelist` subnet regex stays** (`targets/vps0/compose/templates/crowdsec/postoverflows/s01-whitelist/internal.yaml`) — uptime-kuma needs the exemption and its container IP isn't fixed; there is no better mechanism.
- **Authelia is deliberately NOT behind geoblock** (operator travels outside the CA/CN/CU allowlist). Crowdsec on the srv0 `auth` route is fine; geoblock is not.
- **Public-by-design services**: seerr (geoblock only, no SSO — deliberately shareable), cct26 on vps0 (fully open, no geoblock — deliberate), owncast RTMP ingest :1935 (relies on a strong stream key set in the Owncast admin UI, can't be Traefik-gated).
- **Public hosts deliberately without SSO and/or geoblock** — srv0: `gpt` (Open WebUI), `fmd`, and `rss` (FreshRSS) are public with geoblock + crowdsec only (their own app auth, no Authelia); `tv` (Jellyfin) has crowdsec + `authelia-with-optional-header-gate` + ratelimit but no geoblock. vps0: `plausible` (crowdsec only) and `ytdl` (metube; crowdsec + Authelia `one_factor`) have no geoblock. All deliberate — don't propose adding SSO or geoblock to any of these.
- **Home Assistant gets the ConBee II via CDI, not `privileged`** (`targets/srv0/k3s/cdi-specs/` + `homeassistant/helmchart.yaml`) — the device cgroup blocks unprivileged opens of `/dev/ttyACM0`, so HA requests the `infra.local/devices-conbee` resource. The `cdi-specs` component runs cluster-wide: each node generates its own CDI spec in `/etc/cdi` from its actual `/dev` (grants follow the hardware, not a node label), and the `cdi-device-plugin` DaemonSet registers them. HA still needs pod-level `seLinuxOptions.type: spc_t` (SELinux denies `container_t` the mounted `/run/dbus/system_bus_socket` — Bluetooth integration → host bluez — and the device; verified empirically) plus `capabilities.add: [NET_ADMIN, NET_RAW]` (habluetooth manages the host adapter via direct HCI sockets; since hostNetwork was removed — auto-discovery unused — these apply to the pod netns only). Device cgroup access is scoped to the ConBee II alone. Don't propose re-adding privileged.
- **Jellyfin gets /dev/dri via CDI, not `privileged`** (`targets/srv0/k3s/jellyfin/helmchart.yaml`) — requests `infra.local/devices-dri`, runs `container_t` as `$MY_UID`, no spc_t needed (renderD128 is 0666 + container_t-accessible). Device cgroup scoped to the render node. frigate/immich get the same grant (container_t + s0, pinned to srv0 — frigate keeps CAP_PERFMON but loses the dashboard GPU-stats graph: SELinux denies container_t perf_event_open); promtail and the CDI plugin run spc_t instead of privileged; pvc-backup/restore pods are non-privileged (spc_t + DAC_OVERRIDE/FOWNER); ollama uses the `infra.local/devices-amd` grant (kfd + dri, bigpc) with container_t + s0; mosquitto runs as uid 1883. nfs-server ingress is allowlisted to the node CIDR on TCP 2049 (all shares nfsvers=4.2, CSI mounts are node-sourced).
- **nfs-server stays `privileged`** (`targets/srv0/k3s/nfs-server/deployment.yaml`) — it runs a kernel NFS server (`nfsd`/`rpc.mountd`) in-container, which genuinely requires privileged. Internal base component, no ingress; don't propose de-privileging it.
- **vps0 Authelia `one_factor` rules are intentional** for ytdl/ikom/sale (family/guests); only the admin catch-all rule is `two_factor` (TOTP is Authelia's default second factor — no `default_second_factor_policy` needed).
- **srv0 PROXY-protocol trustedIPs include pod/service CIDRs on purpose** (`targets/srv0/k3s/traefik/traefik.yaml`) — frpc connects to `127.0.0.1:8443`, but the port is served by a klipper-lb `svclb` pod (host network) which forwards to the Traefik Service; kube-proxy SNAT makes the Traefik pod see pod/service-CIDR sources, and the PROXY v2 header (emitted by vps0's Traefik `serversTransport frps-proxy`, `dynamic-configuration.yaml`) rides inside the tunnel stream. Untrusted sources would leave the header unparsed and corrupt the TLS stream — narrowing below these CIDRs breaks `home.*`. Consequence accepted: any pod can spoof a PROXY header to the host port.
- **CrowdSec bouncer `clientTrustedIPs` is a client bypass-whitelist, not an XFF/proxy setting** (per the plugin README: "List of client IPs to trust, they will bypass any check from the bouncer or cache"). XFF trust is `forwardedHeadersTrustedIPs` (both stacks: `127.0.0.1/32` only). vps0 removed its `clientTrustedIPs: 172.19.0.0/24` — docker-network callers are exempted from decisions at the crowdsec layer via the `s01-whitelist` postoverflow instead. Don't reintroduce `clientTrustedIPs` to "fix" internal traffic.
- **Agents must never read `secrets/` or any VARS file** — secrets are private by design; audits check gitignore coverage and git history, not file contents.

## Manual first-time setup (srv0 apps)

One-time web-UI setup steps for the apps that have no API seeding:

- **radarr / sonarr** (`https://radarr.$SERVICES_DOMAIN`, `https://sonarr.$SERVICES_DOMAIN`, Authelia-protected): General → Authentication → Forms (create admin account); Media Management → Root Folders (`/data/Movies` for radarr, `/data/TV` for sonarr); Download Clients → qBittorrent at `qbittorrent.apps.svc.cluster.local:8080` (credentials from the qBittorrent setup); Indexers via Prowlarr or manual; Connect → Jellyfin (`http://jellyfin.apps.svc.cluster.local:8096`, API key from the Jellyfin dashboard, notify On Import/On Upgrade). The arr API keys are pre-configured: `kubectl -n apps get secret radarr-secret|sonarr-secret`.
- **prowlarr** (`https://prowlarr.$SERVICES_DOMAIN`): Settings → Apps → add Radarr (`http://radarr.apps.svc.cluster.local:7878`) and Sonarr (`http://sonarr.apps.svc.cluster.local:8989`) with keys from their secrets; Settings → Indexers (auto-syncs to Radarr/Sonarr). For Cloudflare-protected indexers, add FlareSolverr (`http://flaresolverr.apps.svc.cluster.local:8191`).
- **seerr** (`https://seerr.$SERVICES_DOMAIN`): sign in with the Jellyfin account (`http://jellyfin.apps.svc.cluster.local:8096`); Settings → Services → add Jellyfin, Radarr, Sonarr (same URLs/keys as above).
- **Frigate → Home Assistant**: MQTT integration once (`broker: mosquitto`, `port: 1883`, `user: homeassistant`, password = `HA_MQTT_PASSWORD` from VARS), then the Frigate integration (`URL: http://frigate:5000`, internal unauth port). Frigate's MQTT discovery auto-creates camera/event entities; the dashboard is auto-provisioned (core cards only — no custom components; the Advanced Camera Card is installed by the HA `integration-update` init container, served at `/local/community/advanced-camera-card-2026/dist/...`). Recordings land on NFS (`$SECONDARY_STORAGE_PATH/frigate`). Gotchas: iframe embeds of the Frigate UI don't work (Authelia `X-Frame-Options: DENY`); the HA companion app may cache a stale frontend (clear app storage); if the rpi go2rtc password file is deleted, update `FRIGATE_RTSP_PASSWORD` in VARS and re-apply frigate.

## Updates (Renovate)

Renovate runs **automatically every day at 17:00 America/Toronto** as the `renovate` K3s CronJob on srv0 (base group, `targets/srv0/k3s/renovate/`) — the full `renovate/renovate` image (ships the Go toolchain, so the gomod manager works). The pod mounts only two files of the syncthing-synced repo (`secrets/VARS.env` and `.git/config`, read-only) to source `RENOVATE_GITHUB_TOKEN` (auto-rotates on sync) and to infer `RENOVATE_GIT_AUTHOR`; Renovate itself clones from GitHub. `ansible-playbook ansible/playbooks/renovate.yaml [-e renovate_args="--dry-run"]` (runs `scripts/renovate.sh`) is the manual/on-demand equivalent for other machines (needs Node/npm and `go` from prereqs for gomod updates; runs on the machine you're on, opening PRs directly on GitHub).

Review/apply flow (manual only for critical infra; automerge for everything else per scope below): fetch the PR branch (`git fetch origin pull/<n>/head:renovate/pr-<n>`, then `git checkout renovate/pr-<n>`), `ansible-playbook ansible/playbooks/validate.yaml`, then merge locally and `git push origin master`. Merges never happen in the platform UI — origin stays the source of truth. Renovate rebases its open PRs and auto-closes them once the change lands on `master` (next run).

**Automerge scope** — Renovate auto-merges anything *not* matching the critical-infra exclusion (packageRules `matchFileNames` + `matchUpdateTypes`). For critical infra — srv0 K3s base group (namespaces, nfs-server, host-volumes, csi-driver-nfs, cert-manager, longhorn, geoip, traefik, crowdsec, authelia, pvc-backup, ntfy, descheduler, system-upgrade, rustfs, monitoring), vps0 compose (public edge), and the srv0 frpc tunnel compose — only **major** updates stay manual; minor/patch automerges normally. Longhorn exception: patches automerge, but **minor** bumps are proposed without automerge (sequential minor upgrades are mandatory — never merge a minor skip). The grouped docker-digests PR is always manual (it mixes base images). Everything else — apps-namespace k3s components, pc/bigpc/rpi compose, unmanaged arr-stack dirs — automerges including majors (no CI gate; a merged change only deploys when you next run `compose install`/`k3s group apply`).

**Watchtower vs Renovate ownership** — watchtower runs only on pc/bigpc and updates every local container *without* the `com.centurylinklabs.watchtower.enable=false` label — in practice just compose `syncthing/syncthing` (kept untagged; socket-proxy is labeled false). Renovate ignores `syncthing/syncthing` under the docker-compose manager only, so the srv0 K3s syncthing (pinned tag) stays Renovate-managed. Everything else is Renovate's (srv0/vps0/rpi have no watchtower at all). Watchtower's own image is digest-pinned by Renovate (`nickfedor/watchtower:latest`) since watchtower never self-updates.

`renovate.json` at root (repository config): built-in **kubernetes** manager (`managerFilePatterns: /^targets\/srv0\/k3s\/.*\.ya?ml$/` — plain pod-spec images incl. the hook Jobs and vendored system-upgrade manifests) and **docker-compose** manager (all compose images) plus four regex managers, all retargeted to `targets/srv0/k3s/.+\.ya?ml$`: (1) images inside HelmChart `valuesContent` blocks, (2) HelmChart CR versions (`oci://` via the docker datasource — the helm datasource has no OCI support — or `chart:`+`repo:`+`version:`), (3) K3s plan versions (`github-releases` on `k3s-io/k3s`, custom versioning), (4) Traefik plugin pins in `additionalArguments` (also covers vps0 compose). Global options (token, repo) are set by the runner script, not the repo config. packageRules: pin floating `latest|stable|release|alpine` tags (and every untagged compose image, which carries an explicit `:latest`) to digests and group all digest pins/refreshes into one PR (prHourlyLimit 20); block majors for `postgres`, `clickhouse/clickhouse-server`, `fedora` (the former inline `# PRESERVE_MAJOR` comments became package-level rules — Renovate can't read inline comments); disable syncthing (compose; watchtower-owned on pc/bigpc) and the frozen moving-sale site image. Longhorn minor PRs are never automerged (sequential minor upgrades required); immich's postgres image gets custom regex versioning (same-shape `18-vectorchordX.Y.Z-pgvectorA.B.C` tags only, postgres major locked via the compatibility group); the WASM plugin's go.mod is gomod-managed via the CronJob's Go toolchain. No other annotations — Renovate's default update decision applies everywhere.

Compose image ownership:
| Where | Updater |
|---|---|
| srv0 (frpc), pc/bigpc compose | Renovate PRs; watchtower (pc/bigpc) auto-updates only compose syncthing |
| vps0 compose (pinned or digest-pinned) | Renovate PRs (no watchtower on vps0) |
| Floating/untagged k3s + compose images | Renovate digest-pin PRs (tag stays, digest refreshed) |

Post-update: `git diff` → `ansible-playbook ansible/playbooks/validate.yaml` → deploy.

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
```
ansible.cfg                    # Root ansible.cfg: roles_path ./ansible/roles (~/.ansible fallback); auto-discovered from the repo root
infra                          # Everyday entry point: thin wrapper that cd's to the repo root and execs ansible-playbook
ansible/                        # Ansible: playbooks/ (compose_install|restart|backup_state, validate,
                                #   prereqs, wireguard, renovate, preboot, k3s_server|join +
                                #   vars/k3s.yaml shared provisioning policy) + roles/ (compose, preboot,
                                #   prereqs, k3s_install|node_extra|configure) + requirements.yaml + lint configs
scripts/                        # common.sh (env bootstrap + helpers for retained scripts) + renovate.sh
                                #   (run Renovate — invoked by renovate.yaml)
secrets/                        # VARS.<target>.yaml (plain YAML, gitignored), VARS.env
targets/<target>/
  VARS.template.yaml            # Documents every required variable + generation commands
  compose/compose.yaml          # $VARIABLE placeholders (docker-compose native interpolation)
  compose/compose.private.yaml  # Optional gitignored overlay, merged over compose.yaml
  compose/templates/            # .secret/.plain jinja2 render pipeline (ansible compose role)
  *.yaml                        # Target-root playbooks (host hardcoded): srv0 helm_apply.yaml
  *.sh                          # Retained payload scripts (srv0: pvc.sh backup|restore,
                                #   update-node-ip.sh — run in-cluster or directly on the target)
  k3s/                           # srv0 umbrella Helm chart (k3s-specific: HelmChart CRs, k3s
                                #   traefik HelmChartConfig, k3s plan versions): templates/ (repo-owned
                                #   components + HelmChart CRs + hook Jobs), files/ (WASM plugin),
                                #   plugins/ (WASM plugin source), values.yaml (committed defaults;
                                #   secrets in secrets/VARS.srv0.yaml)
current_target/compose_live_state/   # Rendered state (gitignored, ephemeral)
compose_state_backups/ k3s_state_backups/   # Backup archives (gitignored)
architecture.svg|.excalidraw        # Architecture diagram
```

## Environment variables (always available)

For retained bash scripts: `$INFRA_ROOT` (repo root, self-computed by `scripts/common.sh` unless pre-set), `$TARGET`, `$COMPOSE_STATE_DIR` (`current_target/compose_live_state`), `$PVC_BACKUP_DIR` (`k3s_state_backups`), `$MY_UID` (current UID, forced 1000 when root). Ansible playbooks derive the repo root from `playbook_dir` (no env needed); `$DOCKER_GID`/`$PROXY_IP` are resolved by the compose role (`getent`).

## Rules

- **The target is always explicit** — target-selecting ops (compose, validate, helm, pvc) name their target (`infra <t> <op>`, or `-e target=<t>`); nothing infers it from the hostname.
- **Always apply changes through the playbooks** — never raw `docker compose`/`kubectl` for mutations. Direct inspection (logs, get, describe, curl) is fine.
- **K3s node provisioning goes through `k3s_server.yaml`/`k3s_join.yaml` only** — never raw installers or ad-hoc joins; the playbooks supply the verified-installer and secret-handling setup. Dev-only lint (`ansible-lint`/`yamllint`/`shellcheck`) touches nothing.
- Never edit files under `current_target/` (rendered output).
- Never commit secrets (VARS files, `compose.private.yaml` are gitignored).
- New components must follow the sizing tiers and include NetworkPolicies.
