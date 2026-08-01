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
| `pc0` | Compose | Owncast streaming PC |
| `vps1` | Compose | Secondary VPS + FRP server for pc0 |

## Essential commands

```
./infra.sh <target> validate                     # YAML + kustomize + var-reference check
./infra.sh <target> list-domains                 # Host(...) domains from IngressRoutes & Compose
./infra.sh <target> compose install              # Render templates, install systemd unit, start
./infra.sh <target> compose restart <service>    # Re-render templates + restart single service
./infra.sh <target> compose backup-state [remote]
./infra.sh <target> compose generate-frp-certs <server-target>  # mTLS certs for FRP pair
./infra.sh <target> k3s setup                    # Bootstrap a K3s control-plane node
./infra.sh <target> k3s join <ip> <user> [agent|server]
./infra.sh <target> k3s group base apply|initial|delete
./infra.sh <target> k3s group apps apply|initial|delete
./infra.sh <target> k3s deploy <component> [apply|initial|delete|diff|yaml]
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
- **`# IGNORE INITIALLY`** — on first render (destination doesn't exist), lines ending with this are commented out (Compose) or removed (K3s `initial` mode). On subsequent runs they're fully included. Used for bootstrap dependencies.
- **`_HASHABLE` → `_HASHED`** — variables ending in `_HASHABLE` are auto-hashed with `openssl passwd -6` into a corresponding `_HASHED` variable.
- **Multi-line vars** preserve YAML indentation — whitespace in export values matters.
- **Template rendering pipeline:** `compose.yaml` and `templates/*` → `current_target/compose_live_state/`. Never edit files in `current_target/`.

## K3s conventions

- **`kubectl kustomize` → `envsubst` → `kubectl apply`** — all component YAML goes through this pipeline. `$VARIABLE` references work in any YAML file.
- **`groups.yaml`** — deploy order = listed order; delete order = reverse. Deleting `base` refuses if Bound PVCs exist (must delete `apps` first).
- **Hook scripts:** `prep.sh` runs before apply, `post.sh` after, `delete.sh` before standard deletion.
- **`wait_for_crds(timeout_seconds, crd1 crd2...)`** — helper for `post.sh` hooks to wait until CRDs are established.
- **Storage:** Longhorn (primary) at `$K3S_STATE_DIR`; NFS retained as fallback. PVC backups at `$PVC_BACKUP_DIR`.

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

- `renovate.json` at repo root — three regex customManagers scan K3s YAML files only (`targets/.+/k3s/.*\.yaml$`) for Docker images and Helm charts.
- **`--require-config=required`** — Renovate has no default behavior; only scans what `renovate.json` defines.
- `_apply_updates.py` reads Renovate debug output via stdin and modifies source files directly (no PRs).
- **`# PRESERVE_FULL`** comment — skip this line entirely during updates.
- **`# PRESERVE_MAJOR`** comment — skip major version bumps for this line.
- Traefik plugins are checked separately via GitHub Releases API (not via Renovate).
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
