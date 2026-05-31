# Architecture

## Overview

Atlas is a single-repo infrastructure-as-code system where one CLI entry point (`atlas.sh`) dispatches commands against named machines ("targets"). There is no build step, no compilation, no server-side agent. Everything runs from shell scripts invoked on the machine being managed.

```
User runs:  ./atlas.sh <target> <command> [args...]
                              │
                              ▼
                    atlas.sh entry point
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         lib/common.sh   lib/dispatch.sh   VARS.<target>.sh
         (core library)   (command router)   (secrets/env)
                              │
                              ▼
                     Command resolution
                     ┌──────────────────┐
                     │ targets/<T>/     │  ← target-specific overrides
                     │   commands/      │
                     │ commands/        │  ← global commands
                     └──────────────────┘
                              │
                              ▼
                     Command execution
                     (bash or python3)
```

## Key directories

| Directory | Purpose |
|-----------|---------|
| `atlas.sh` | Main CLI entry point. Sets up environment, sources libraries, dispatches commands. |
| `lib/` | Shared library code. `common.sh` has reusable functions; `dispatch.sh` has the command router. |
| `commands/` | Global command implementations. Shared across all targets. |
| `targets/` | Per-machine configuration. Each subdirectory is one target with its Compose and/or K3s definitions. |
| `current_target/` | Runtime state directory (gitignored). Holds rendered Compose files, secrets, Longhorn backups. |
| `cache/` | Runtime cache (gitignored). Renovate cache, etc. |

## The dispatch system

`atlas_dispatch()` in `lib/dispatch.sh` is the core routing engine. It resolves a command string like `compose install` to an executable script by searching two directories in order:

1. **Target-specific override:** `targets/<target>/commands/<path>/<cmd>.sh`
2. **Global default:** `commands/<path>/<cmd>.sh`

This allows targets to override any command while falling back to the shared implementation. The router supports nested subcommands (e.g., `k3s group base apply` resolves through multiple directory levels) and both `.sh` (bash) and `.py` (python3) scripts.

Two commands are "built-in" and handled directly in dispatch without script resolution: `validate` and `list-domains`.

## Target abstraction

Every machine managed by Atlas is a "target." Each target has its own directory under `targets/` containing:

- `VARS.template.sh` — documents required environment variables
- `compose/compose.yaml` — Docker Compose definition (if this target runs Compose)
- `compose/templates/` — config file templates for Compose services
- `k3s/` — K3s component directories (if this target runs Kubernetes)
- `k3s/groups.yaml` — deployment grouping and ordering
- `commands/` — optional target-specific command overrides

Targets are flexible — see [targets.md](targets.md) for the current target lineup.

## Variable/secret model

Configuration values are `$VARIABLE` placeholders in YAML/TOML/JSON files. At runtime, a per-target environment file (`VARS.<target>.sh`) is sourced to export all needed variables. `envsubst` performs substitution.

Template files (*.secret, *.plain) under `compose/templates/` are rendered into the runtime state directory (`current_target/compose_live_state/`). `.secret` files get `chmod 600` after rendering. See [variables-and-templating.md](variables-and-templating.md).

## Execution flow

1. `atlas.sh` starts, sets `ATLAS_ROOT`, detects interactive mode, validates the target exists
2. Sources `lib/common.sh` (guarded against double-loading via `ATLAS_LIB_LOADED`)
3. Looks for `VARS.<target>.sh` — sources it, computes `ENVSUBST_VARS`
4. Checks Docker availability if the command is `compose` or `k3s`
5. Sources `lib/dispatch.sh` and calls `atlas_dispatch()` with remaining arguments
6. `atlas_dispatch()` finds and executes the matching script

## File conventions

- `# DESC:` — the second line of each command script is a description shown in `--help`
- `ATLAS_ROOT` — absolute path to the repo root, always available
- `TARGET` — name of the current target, always available
- `COMPOSE_STATE_DIR` — where rendered Compose files live at runtime
- `ENVSUBST_VARS` — space-separated list of `$VARIABLE` names for envsubst
- `.secret` — file extension marking templates that should be rendered with restricted permissions
- `.plain` — file extension marking templates that should be copied verbatim without envsubst

## Two orchestrators

Atlas supports two workload orchestrators, and a target can use either or both:

**Docker Compose** — Simple service composition. Each target with Compose gets a systemd unit that runs `docker compose up/down`. Suitable for VPS-style deployments.

**K3s (Kubernetes)** — Full container orchestration. Used for the primary homelab server. Components are deployed via `kubectl kustomize` with a hook-based lifecycle.

A single target can run both orchestrators simultaneously (e.g., a Kubernetes node with a Compose sidecar for FRP tunneling).

## Data flow

```
VARS.<target>.sh (secrets & env vars)
    │
    ▼
targets/<target>/compose/templates/*   ──envsubst──►  current_target/compose_live_state/
targets/<target>/compose/compose.yaml  ──envsubst──►  current_target/compose_live_state/compose.yaml
    │                                                         │
    │                                                    docker compose up -d
    │
targets/<target>/k3s/*/kustomization.yaml
    │
    ▼
kubectl kustomize  ──►  YAML  ──envsubst──►  kubectl apply -f -
```
