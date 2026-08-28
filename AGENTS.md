# AGENTS.md

Infra is a shell-driven IaC repo for a multi-machine homelab. One CLI (`./infra.sh <target> <command>`) dispatches commands against named machines.

## Prerequisites

- Bash 4+, Docker Compose v2, kubectl (for K3s targets), yq, envsubst, jq, curl, python3
- Install with: `./infra.sh <target> prereqs`

## Targets

| Target | Orchestrator | Role |
|--------|-------------|------|
| `srv0` | K3s (primary) + Compose sidecar | Main home server, LUKS-encrypted root |
| `vps0` | Compose | Web-services VPS + FRP server |

## Essential commands

```
./infra.sh <target> validate                     # YAML + kustomize + var-reference check
./infra.sh <target> list-domains                 # Host(...) domains from IngressRoutes & Compose
./infra.sh <target> compose install              # Render templates, create host dirs, start stack
./infra.sh <target> compose restart <service>    # Re-render templates + restart single service
./infra.sh <target> compose backup-state [remote]
./infra.sh <target> compose generate-mtls-certs <server-target>  # mTLS certs for a client↔server pair
./infra.sh <target> k3s setup                    # Bootstrap a K3s control-plane node
./infra.sh <target> k3s join <ip> <user> [agent|server]
./infra.sh <target> k3s group base apply|delete
./infra.sh <target> k3s group apps apply|delete
./infra.sh <target> k3s deploy <component> [apply|delete|diff|yaml]
./infra.sh <target> k3s update-node-ip
./infra.sh <target> k3s test-storage <size>
./infra.sh <target> k3s restore-pvc <name> [-y]
./infra.sh <target> update [--dry-run]           # Renovate scan + apply updates + Traefik plugins
./infra.sh <target> wireguard <config-path>
```

## Dispatch system: how commands resolve

`infra_dispatch()` walks the argument list as directory levels, searching:

1. `targets/<target>/commands/` — target-specific override (checked first)
2. `commands/` — global default

Seen as both `.sh` scripts (must be `chmod +x`) and `.py` (python3). Directory entries become subcommand levels. `validate` and `list-domains` are **built-in** — they bypass script resolution entirely.

## Directory layout

```
targets/<target>/
  VARS.template.sh              # Required variables doc (committed to git)
  compose/compose.yaml          # Compose definition with $VARIABLE placeholders
  compose/templates/            # Config templates rendered at deploy time
  k3s/<component>/              # One dir per deployable K3s unit
    kustomization.yaml          # Required. Standard kustomize resources list.
    prep.sh / post.sh           # Optional hooks (run before/after apply)
    delete.sh                   # Optional custom delete hook
  k3s/groups.yaml               # Ordered deployment groups (base, apps)
  commands/                     # Target-specific command overrides

commands/                       # Global command implementations
commands/_internal/             # Internal helpers (e.g. _apply_updates.py)

current_target/compose_live_state/   # Rendered Compose state (gitignored, ephemeral)
```

## Variable and template conventions

- **`VARS.template.sh`** — committed; documents all required `export VARIABLE="value"` entries
- **`VARS.<target>.sh`** at repo root — actual secrets; gitignored. Also supports `VARS.sh` as fallback.
- **`$ENVSUBST_VARS`** — allowlist of variable names for `envsubst`; only known vars are expanded. Built automatically from the VARS file.
- **`.secret`** suffix → envsubst + `chmod 600`, suffix stripped
- **`.plain`** suffix → copied verbatim (no envsubst), suffix stripped
- **`_HASHABLE` → `_HASHED`** — variables ending in `_HASHABLE` are auto-hashed with `openssl passwd -6` into a corresponding `_HASHED` variable.
- **Multi-line vars** preserve YAML indentation — whitespace in export values matters.
- **Template rendering pipeline:** `compose.yaml` and `templates/*` → `current_target/compose_live_state/`. Never edit files in `current_target/`.

## K3s conventions

- **`kubectl kustomize` → `envsubst` → `kubectl apply`** — all component YAML goes through this pipeline. `$VARIABLE` references work in any YAML file. ConfigMaps with `binaryData` are applied via `kubectl apply --server-side` (client-side apply's `last-applied-configuration` annotation exceeds the 256KiB limit for large binaries); everything else is client-side.
- **Authelia header gate (srv0 only)** — `AUTHELIA_HEADER_GATE_ENABLED` controls the `authelia-header-gate` Traefik WASM plugin middleware (`"true"` = 401 without an Authelia session). Auto-enabled on first deploy when the `authelia` Service is absent from `base`; the VARS value (default `"false"`) wins otherwise. Services that are publicly accessible after bootstrap use the `authelia-with-optional-header-gate` chain (Authelia `bypass` + gate). vps0 does not use the gate.
- **`groups.yaml`** — deploy order = listed order; delete order = reverse. Deleting `base` refuses if Bound PVCs exist (must delete `apps` first).
- **Hook scripts:** `prep.sh` runs before apply, `post.sh` after, `delete.sh` before standard deletion.
- **`wait_for_crds(timeout_seconds, crd1 crd2...)`** — helper for `post.sh` hooks to wait until CRDs are established.
- **Storage:** Longhorn (primary) at `$K3S_STATE_DIR`; NFS retained as fallback. PVC backups at `$PVC_BACKUP_DIR`. `pvc-backup-dest` binds to the static PV `pvc-backup-dest-pv`, which mounts the ROOT of the NFS `backups` share (hostPath `$PVC_BACKUP_DIR` on the hostpath-main node) — backup pods write human-named archives directly into `$PVC_BACKUP_DIR` from any node; no dynamically provisioned `pvc-*` subdirs exist.

## Resource sizing tiers (use these, never ad-hoc)

| Tier | K8s limits/requests | Compose mem_limit |
|------|---------------------|-------------------|
| small | 512Mi / 128Mi | 512M |
| medium | 2Gi / 128Mi | 2G |
| large | 8Gi / 2Gi | 8G |

| Storage tier | PVC size |
|------|----------|
| small | 5Gi |
| medium | 50Gi |
| large | 200Gi |
| 4Ti | 4096Gi |

## Updates (Renovate)

- `renovate.json` at repo root — four regex customManagers scan K3s YAML files only (`targets/.+/k3s/.*\.yaml$`) for Docker images, Helm charts, and K3s upgrade-plan versions.
- **`--require-config=required`** — Renovate has no default behavior; only scans what `renovate.json` defines.
- `_apply_updates.py` reads Renovate debug output via stdin and modifies source files directly (no PRs).
- **`# PRESERVE_FULL`** comment — skip this line entirely during updates.
- **`# PRESERVE_MAJOR`** comment — skip major version bumps for this line.
- Traefik plugins are checked separately via GitHub Releases API (not via Renovate).
- K3s binary upgrades: the `system-upgrade` component (system-upgrade-controller + `server-plan`/`agent-plan`). Plan versions are Renovate-managed; `prep.sh` always applies the latest SUC manifests from GitHub. Apply with `./infra.sh <target> k3s deploy system-upgrade apply` and watch `kubectl -n system-upgrade get plans,jobs`.
- Post-update: `git diff` → `./infra.sh <target> validate`.

## Key environment variables (always available)

- `$INFRA_ROOT` — absolute path to repo root
- `$TARGET` — current target name
- `$COMPOSE_STATE_DIR` — rendered Compose state (gitignored)
- `$COMPOSE_STATE_BACKUP_DIR` — backup archives
- `$K3S_STATE_DIR` — Longhorn-backed persistent storage path
- `$PVC_BACKUP_DIR` — PVC backup archives
- `$MY_UID` — current user's UID (forced to 1000 when root)
- `$DOCKER_GID` — Docker group GID
- `$PROXY_IP` — resolved from `$PROXY_HOST`

## Applying changes

Always apply changes to machines through `./infra.sh` commands (`compose install`, `compose restart <service>`, `k3s deploy`, `k3s group ...`) — never raw `docker`/`docker compose`/`kubectl` for mutations. Direct inspection (logs, `docker inspect`, `curl`, `kubectl get`) is fine.

## Writing a new command

```bash
#!/bin/bash
# DESC: Short description (shown in help)
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
# ... implementation ...
```

The second line `# DESC:` is parsed by the help system. Commands are sourced, not executed in a subshell — `exit` will kill the parent.

## Documentation

Read in order: `docs/architecture.md` → `docs/targets.md` → `docs/commands-and-dispatch.md` → `docs/variables-and-templating.md` → `docs/compose-management.md` → `docs/k3s-management.md` → `docs/networking.md` → `docs/security.md` → `docs/standard-vs-custom.md` → `docs/updates-and-renovate.md`
