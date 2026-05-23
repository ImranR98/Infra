# Atlas

Atlas is a single-repo infrastructure manager. It deploys, configures, validates, and tears down services across multiple machines — using Docker Compose on some, K3s (lightweight Kubernetes) on others — all from one entry point.

## Quick start

```bash
# Install system prerequisites
./atlas.sh <target> prereqs

# Deploy everything
./atlas.sh <target> compose install        # Docker Compose stack
./atlas.sh <target> k3s install <component> initial  # K3s component (first run)
./atlas.sh <target> k3s install <component>          # K3s component (re-run after deps ready)

# See what's available
./atlas.sh <target>                        # List commands
./atlas.sh <target> list-domains           # Show DNS domains needed
./atlas.sh <target> validate               # Check configs for errors
```

## Architecture

### Directory structure

```
Atlas/
├── atlas.sh                  # Entry point — ~140 line dispatcher
├── commands/                 # Generic commands (shared across targets)
│   ├── prereqs.sh
│   ├── compose/
│   │   ├── install.sh
│   │   ├── restart.sh
│   │   └── ...
│   └── k3s/
│       ├── setup.sh           # K3s cluster bootstrap
│       ├── install.sh          # Component deploy/delete
│       └── update.py           # Version pinning
├── targets/                   # Per-machine definitions
│   └── <name>/
│       ├── VARS.template.sh   # Required env vars for this target
│       ├── commands/          # Target-specific command overrides
│       ├── compose/           # Docker Compose stack
│       │   ├── compose.yaml
│       │   └── templates/     # Config files with $VAR substitution
│       └── k3s/               # Kubernetes components
│           ├── <component>/
│           │   ├── kustomization.yaml
│           │   ├── *.yaml
│           │   └── post.sh   # Optional post-apply hook
│           └── ...
├── lib/
│   └── common.sh              # Shared functions (all stacks)
├── current_target/            # Runtime state (gitignored)
└── VARS.<target>.sh           # User secrets/config (gitignored)
```

### How atlas.sh works

`atlas.sh` is a thin dispatcher. It does not contain any deployment logic.

1. **Target validation** — checks that `targets/<name>/` exists. Targets are discovered from the filesystem, not hardcoded.
2. **Environment setup** — sources the user's `VARS.<target>.sh`, validates against `targets/<target>/VARS.template.sh`, exports derived variables (`ATLAS_ROOT`, `TARGET`, `MY_UID`, `DOCKER_GID`, etc.).
3. **Command discovery** — walks the remaining arguments left-to-right, searching two directories in order: `targets/<target>/commands/` (target-specific) then `commands/` (generic). At each step it checks for `<path>/<arg>.sh`, `<path>/<arg>.py`, or `<path>/<arg>/` (a subdirectory to descend into).
4. **Function fallback** — if no script file is found, the last argument is checked (with hyphens converted to underscores) as a function name in `common.sh`. This is how `validate`, `list-domains`, `update-traefik-plugins`, and `old-images` work with no wrapper script.
5. **Execution** — the found script (or function) is called with the remaining arguments and `TARGET` as context.

### VARS system

Each target has a `VARS.template.sh` at `targets/<target>/VARS.template.sh`. This lists every environment variable that target's configuration expects. The user copies the relevant template entries into a file at the repo root (`VARS.<target>.sh` or `VARS.sh`).

At startup, `source_env` validates that the user's VARS file contains every variable listed in the template, then sources it. Templates are committed; user files are gitignored.

### Two stacks

Atlas supports two deployment stacks. A target may use one or both.

**Compose** — traditional Docker Compose. Commands live under `compose/`. Templates use `$VAR` substitution via `envsubst` and are rendered into `current_target/compose_live_state/`, which is then deployed as a systemd service.

**K3s** — lightweight Kubernetes via k3s.io. Each component is a directory under `targets/<target>/k3s/` containing a `kustomization.yaml` and resource YAMLs. Components are applied using `kubectl kustomize | envsubst | kubectl apply`.

### K3s components and APPLY_MODE

K3s components support several modes, passed as the third argument to `k3s install <component>`:

| Mode | Behavior |
|------|----------|
| `apply` (default) | kustomize → envsubst → kubectl apply |
| `initial` | Same as apply, but lines ending in `# IGNORE INITIALLY` are deleted from all component YAML files before kustomize runs |
| `delete` | Runs the component's `delete.sh` (if present), then `kubectl delete` on all resources, then waits for PVCs to drain |
| `diff` | Shows what would change without applying |
| `yaml` | Prints the rendered YAML to stdout |

### `# IGNORE INITIALLY`

Resources that depend on infrastructure not yet available (e.g., cert-manager Certificate objects before cert-manager is installed) can be deferred. Add the file reference to `kustomization.yaml` with a `# IGNORE INITIALLY` comment:

```yaml
resources:
  - helmchart.yaml
  - certificates.yaml # IGNORE INITIALLY
```

When deploying with `APPLY_MODE=initial`, that line is silently removed. On the second run (without `initial`), the resource is included. This is how fresh deployments handle dependency ordering without manual intervention.

### When no wrapper script is needed

Commands whose logic lives entirely in `lib/common.sh` do not need a separate script file. The dispatcher detects functions by converting hyphens to underscores and checking `declare -f`. Currently these are:

- `validate` — validates all stacks for a target
- `list-domains` — prints required DNS domains
- `update-traefik-plugins` — checks and updates Traefik plugin versions across both stacks
- `compose old-images` — lists Docker images older than 60 days

### Runtime state

All runtime state lives under `current_target/` (gitignored):

| Directory | Purpose |
|-----------|---------|
| `compose_live_state/` | Rendered compose configs, acme.json, authelia DB |
| `compose_state_backups/` | Tar backups created by `compose backup-state` |
| `k3s_longhorn_backups/` | NFS export for Longhorn volume backups |

---

## Machines

### luna

A single-node Docker Compose host running external-facing services including Traefik reverse proxy, Authelia SSO, and several web applications.

### lens

A lightweight Docker Compose host that acts as a **proxy gateway**. It runs an FRPS server (Fast Reverse Proxy Server) which tunnels traffic to `sol` through firewalls and NAT. `lens` has a public IP and is the entry point for all traffic destined for `sol`.

### sol

The primary workhorse. Runs both a Docker Compose stack (with FRPC to connect through `lens`) and a K3s Kubernetes cluster. The K3s cluster hosts services for media, home automation, file sync, monitoring, notification delivery, and more — organized into components under `targets/sol/k3s/`.
