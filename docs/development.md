# Development

## Scripts

| Script | Selects | Acts on | Notes |
|---|---|---|---|
| `validate.sh <t>` | target | read-only, any machine | config_template→config completeness/placeholders, helm lint + both-chart render (srv0), compose `../../../config/` mount check, `BOOTSTRAP_PRIVATE_APPS` and static-node-label warnings. Prints variable names only. |
| `restic-restore.sh` | — | this machine (srv0) | lists/restores the State Backups restic repo; `pvc <name>` and `compose srv0|vps0` accept `--live`; defaults to staging |
| `prereqs.sh` | — | this machine | packages (NFS client), pinned helm, Docker bootstrap, machine-fact `.env`, host bind dirs, acme seed |
| `kubeconfig-unlock.sh [--lock]` | — | this machine | read ACL on the k3s kubeconfig + `~/.kube/config` symlink; holds until Ctrl-C; `--lock` cleans up |
| `renovate.sh [apps\|infra\|all]` | — | this machine (opens GitHub PRs) | needs `RENOVATE_GITHUB_TOKEN` in `config/VARS.env`; Node/npm only; `infra`/`all` also run `ci-notify.sh` |
| `renovate-daily.sh [--dry-run\|--derived-only]` | — | in-cluster (`renovate-daily` CronJob) | the scheduled routine: derived nfs pass → apps → app-config conformance → merge derived + app PRs (required `test`) → wait for publishes → full Infra pass → merge Infra non-digest PRs (required `validate`) → notifications, including PRs left open for a non-failure reason |
| `merge-renovate-prs.sh --repos ...` | — | in-cluster | single merge path: waits for checks, requires named checks to be `success`, updates behind branches, merges green Renovate PRs, and writes red/blocked/no-check PRs to `--report`; used for the derived PR, app PRs, and Infra non-digest PRs (skips `infra-digest-pin`) |
| `wait-for-runs.sh --since <ISO>` | — | in-cluster | waits for default-branch push runs and `renovate/*` PR runs to settle; exit 2 on timeout |
| `check-app-configs.sh` | — | this machine / in-cluster | asserts the shared Renovate baseline in every app repo (extends, OSV, dashboard, release age, lockfile maintenance, no automerge); run by `renovate-daily.sh` |
| `deploy.sh srv0 [--dry-run]` | target | this machine (srv0, unlocked kubeconfig) | validate → `srv0-base` → `srv0-apps` → helm-controller/rollout/pod/restart/readiness checks; skips workloads only on NotReady nodes |
| `repos.sh` | — | sourced | single source of truth for the app repo list and the nfs derived path |
| `renovate-notify.sh` | — | this machine / in-cluster | posts newly opened or refreshed `deps` PRs to ntfy; called by `renovate.sh` and `renovate-daily.sh` |
| `ci-notify.sh` | — | in-cluster | one digest for failed app/Infra Actions runs and failed `test` checks on open Renovate PRs; called by `renovate-daily.sh` |
| `preboot.sh public-exposure\|crypt-ssh` | — | this machine | initramfs LUKS unlock; preboot key from `config/<hostname>/public-exposure/` |
| `public-exposure-keygen.sh` | — | srv0 | generates the public-exposure keys/confs into `config/` (idempotent; `--force` rotates) |
| `wireguard.sh <conf>` | — | this machine | deploys a provider wg0.conf (split-/1 routes, endpoint dead-loop route) |
| `remote-access-client.sh <client>` | — | this machine (unlocked kubeconfig) | fetches a generated AmneziaWG client profile from the remote-access-amneziawg pod's PVC (`--stdout` available) |
| `k3s-server.sh` | — | this machine (becomes control plane) | node prep + installer + server config + the static `hostpath-main`/`external-exposed` labels |
| `k3s-join.sh <ip> <user> [...]` | — | control plane + joining node | token travels via stdin over SSH; taint/optional `--hostpath-main` after Ready |
| `k3s-node-prep.sh` | — | the node (root) | sysctls, firewall, shared by server/join |
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

The bootstrap self-computes the repo root but honors a pre-set `INFRA_ROOT` (the in-cluster pods ship it, and their host paths must not be recomputed). Target-selecting scripts call `require_target "$1"` (warns on hostname mismatch — check flows) or `require_target_host "$1"` (hard-asserts — ops that mutate the machine). Useful `common.sh` helpers: `_confirm`, `get_node_ip`, `wait_for_k3s_cluster`, `set_my_uid`.

### Comment & doc rules

- Explain current behavior and non-obvious WHYs only — never history ("used to", "previously", "replaces the old X"). Past designs live in git history.
- Keep comments minimal: file headers say what the file IS; don't restate code or narrate steps.
- No device names (srv0/vps0/bigpc/pc/rpi) in shared code (`scripts/`) — keep it generic ("the preboot reader reads keys from `config/<hostname>/public-exposure/`", not "from srv0's keys"). Per-device facts belong in `targets/<t>/`; README.md and the docs are the only shared files that may name targets.
- Docs describe the current codebase only; delete migration/historical notes once a migration lands.
- After editing, `grep -rniE 'the old|previously|formerly|replaces the old|is gone' scripts targets` should return nothing but legitimate current-behavior notes.

## Configuration & secrets

- **Layout** — `targets/<t>/config_template/` (committed) documents every secret input: `values.yaml` (k3s helm values) and/or `compose.env` (compose dotenv), plus extra files (mTLS certs, the Authelia users DB). Copy it to `config/<t>/` and fill every value; `config/<t>/` mirrors the template structure exactly and is gitignored. Templates carry generation commands where possible (e.g. `openssl rand -hex 32`); `validate.sh` rejects leftover placeholders.
- **srv0 — split by consumer** — `config/srv0/values.yaml` feeds only the k3s charts (both, via `helm upgrade -f`). The public-exposure client takes `config/srv0/compose.env` (`PUBLIC_EXPOSURE_HOST`/`PUBLIC_EXPOSURE_PORT`, passed with `docker compose --env-file`) and its WireGuard conf as a real 0600 file under `config/srv0/public-exposure/`; `scripts/public-exposure-keygen.sh` generates every key/conf and also writes the qBittorrent tunnel keys into `values.yaml`.
- **vps0 — dotenv only** — `config/vps0/compose.env` is consumed natively by compose via `--env-file`; no conversion or render step. Multi-line secrets are not dotenv values: the Authelia users DB is `config/vps0/authelia/users_database.yml` and the hub conf is the 0600 file `config/vps0/public-exposure/pubexp-server0.conf` (mounted `:ro`). Machine facts come from the prereqs-generated `targets/vps0/compose/.env`, passed as a second `--env-file` (later file wins).
- **pc/bigpc/rpi — machine facts only** — no `config_template/` (no secret variables). `prereqs.sh` writes `targets/<t>/compose/.env` with `MY_UID`/`DOCKER_GID`/`MY_USERNAME` for **every** target (config envs never carry per-machine facts): vps0 passes it as a second `--env-file`, srv0's public-exposure client takes only the config env, and pc/bigpc/rpi get it auto-loaded as the project-dir `.env`.
- **No encryption** — values sit as plain text under the gitignored `config/`.
- **Format** — values.yaml: `KEY: value`; multi-line values are literal block scalars (`|`), spliced verbatim by helm (`| indent "N"`); inline comments work after single-line values; bare `$` and `#` are literal (write `$argon2id$...` unescaped). compose.env: `KEY=value`; single-quote values containing `$` (compose interpolates inside double quotes); multi-line values use `\n` escapes; inline comments work after single-line values.
- **Validation** — `validate.sh <target>` asserts every template file has a filled counterpart at the same relative path, rejects placeholders (`change_me`/`changeme`/`abc`/`REPLACE_ME`/`<...>`), checks values.yaml/compose.env key completeness both ways (missing *and* extra/dead keys), verifies compose `../../../config/` mounts exist, warns when `BOOTSTRAP_PRIVATE_APPS` is true, warns if the srv0 node is missing the static labels, and for srv0 lints + templates both charts (missing values surface as `<no value>` render failures) and checks that every Gateway listener `certificateRef` resolves to a rendered Certificate (the two shared edge Certificates), with cross-namespace refs covered by a `ReferenceGrant`.
- **Universal VARS** — target-agnostic secrets live in `config/VARS.env` (dotenv; template `config_template/VARS.env`). Commands load it on demand (`renovate.sh` requires `RENOVATE_GITHUB_TOKEN`; the `renovate-daily` CronJob sources it through `scripts/renovate-daily.sh`). `INFRA_REPO`/`APP_REPOS` also live there and are required by `scripts/repos.sh` for the Renovate/CI routines. It is not template-validated — each command checks its own variables.
- **WireGuard keys** — generated by `scripts/public-exposure-keygen.sh` (idempotent, `--force` rotates); keys/confs live as real 0600 files under `config/srv0/public-exposure/`, with the hub conf staged under `config/vps0/public-exposure/` for copying to vps0.
- **`*_HASHED` (k3s authelia)** — precomputed hashes stored in the same YAML next to their `*_HASHABLE` plaintexts (`openssl passwd -6` or `authelia crypto hash generate pbkdf2`; commands are in the template).

## Compose

- **Files** — `targets/<t>/compose/compose.yaml` plus an optional gitignored `compose.private.yaml` merged with `-f`. Substitution is native docker compose: `$VAR` values come from `--env-file config/<t>/compose.env` on vps0/srv0, or from the automatically loaded project-dir `.env` on pc/bigpc/rpi. Project name = the `name: <t>` attribute.
- **Inlined configs** — templated configs (the traefik dynamic config, crowdsec notifications/whitelist, logtfy config.json) are top-level `configs:` blocks using `content:` with `$VAR` interpolation (or an `environment: VARNAME` source), granted via the `configs:` long syntax with `target:` and `mode:` (0400 for secret-bearing, 0440 otherwise). Static files — the public-exposure scripts/rules (`files/public-exposure/`), crowdsec acquisitions/profiles, auth.py, clickhouse-config.xml, go2rtc.yaml — live in `targets/<t>/compose/files/` and are bind-mounted `:ro`.
- **vps0 Authelia config** — the structural base lives in `targets/vps0/compose/files/authelia/configuration.base.yml`; deployment-specific rules live in `config/vps0/authelia/access_control.yml`. `scripts/render-vps0-authelia.sh` injects the rules and substitutes `${...}` into `current_target/compose_live_state/authelia/config/configuration.yml`, which the Authelia service mounts at `/config`. Run it manually before `docker compose up`; `validate.sh vps0` runs `render --check` on vps0.
- **State** — `current_target/compose_live_state/` (gitignored) holds runtime state only (acme.json, sqlite DBs, upload dirs), referenced with relative paths (`../../../current_target/compose_live_state/...`, resolved against the compose file's directory). `prereqs.sh` creates missing bind dirs owned by `$MY_UID` (Docker would create them as root, unwritable by containers running as `$MY_UID`) and seeds `traefik/acme.json` (`{}`, 0600, first run). `current_target/k3s_live_state/` holds the NFS app-data tree; both are gitignored and Syncthing-ignored.
- **Ownership self-heal** — containers with a fixed non-`$MY_UID` user (ClickHouse 101, Plausible 999) have a one-shot `state-fixperms` init service (alpine, `cap_drop: ALL` + `CHOWN`/`FOWNER`/`DAC_OVERRIDE`) that chowns their state dirs before the apps start; dependents gate on it with `condition: service_completed_successfully`. It re-runs after `docker compose down <svc>`, so host-side chown drift is fixed on the next deploy.
- **Deploy** — see `AGENTS.md`; reboot survival comes from per-service `restart:` policies (no systemd wrapper). `content:` configs are materialized into a container only when it is created and are not part of compose's service hash, so a plain `up -d` after editing one leaves the old config in place — recreate the service with `up -d --force-recreate --no-deps <svc>`. `files/` bind mounts are live and need no recreate. The vps0 Authelia config is a bind-mounted generated file; after `render-vps0-authelia.sh`, recreate Authelia so it reloads.
- **Backups** — the Task Runner runs the scheduled `State Backups` task (`config.mjs` → `tools/backup/state-backup.sh`) against the labelled app PVCs and the srv0/vps0 Compose state. It is backup-only; `scripts/restic-restore.sh` is the manual restore path and works on a fresh cluster. The old `pvc.sh`, `pvc-backup` CronJob, and `compose_state_backups/` were removed after a successful staged restic restore.

See `docs/decisions.md` for the accepted duplication list (do not consolidate).
