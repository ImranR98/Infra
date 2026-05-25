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
├── atlas.sh                  # Entry point — dispatcher with built-in commands
├── commands/                 # Generic commands (shared across targets)
│   ├── prereqs.sh
│   ├── update-traefik-plugins.py
│   ├── compose/
│   │   ├── install.sh
│   │   ├── restart.sh
│   │   ├── backup-state.sh
│   │   ├── update-socket-proxy.sh
│   │   └── update-frp.sh
│   └── k3s/
│       ├── setup.sh           # K3s cluster bootstrap
│       ├── join.sh            # Join a worker node
│       ├── install.sh         # Component deploy/delete
│       ├── update.py          # Version pinning
│       └── update-node-ip.sh  # IP change recovery
├── targets/                   # Per-machine definitions
│   └── <name>/
│       ├── VARS.template.sh   # Required env vars for this target
│       ├── commands/          # Target-specific command overrides
│       │   └── k3s/
│       │       ├── base.sh    # Deploy all base components
│       │       └── apps.sh    # Deploy all app components
│       ├── compose/           # Docker Compose stack
│       │   ├── compose.yaml
│       │   └── templates/     # Config files with $VAR substitution
│       └── k3s/               # Kubernetes components
│           ├── <component>/
│           │   ├── kustomization.yaml
│           │   ├── *.yaml
│           │   ├── post.sh    # Optional post-apply hook
│           │   └── delete.sh  # Optional teardown hook
│           └── ...
├── lib/
│   ├── common.sh              # Aggregator — sources all sub-modules
│   ├── packages.sh            # Package manager helpers
│   ├── vars.sh                # VARS file handling + envsubst
│   ├── domains.sh             # Domain listing
│   ├── images.sh              # Old Docker image listing
│   ├── compose-gen.sh         # Compose config generation + render
│   ├── validate.sh            # Stack validation logic
│   ├── wait-for-crd.sh        # CRD wait helper for K3s post hooks
│   └── k3s-common.sh          # K3s installer/helper functions
├── current_target/            # Runtime state (gitignored)
└── VARS.<target>.sh           # User secrets/config (gitignored)
```

### How atlas.sh works

`atlas.sh` is a thin dispatcher. It does not contain any deployment logic.

1. **Target validation** — checks that `targets/<name>/` exists. Targets are discovered from the filesystem, not hardcoded.
2. **Environment setup** — sources the user's `VARS.<target>.sh`, validates against `targets/<target>/VARS.template.sh`, exports derived variables (`ATLAS_ROOT`, `TARGET`, `MY_UID`, `DOCKER_GID`, etc.).
3. **Command discovery** — walks the remaining arguments left-to-right, searching two directories in order: `targets/<target>/commands/` (target-specific) then `commands/` (generic). At each step it checks for `<path>/<arg>.sh`, `<path>/<arg>.py`, or `<path>/<arg>/` (a subdirectory to descend into).
4. **Execution** — the found script is called with the remaining arguments and `TARGET` as context. Shell scripts run via `bash`, Python scripts via `python3`.

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

Resources that depend on infrastructure not yet available (e.g., cert-manager Certificate objects before cert-manager is installed) can be deferred. Add the `# IGNORE INITIALLY` comment on resource lines in `kustomization.yaml`, or on individual YAML lines inside manifests:

```yaml
# In kustomization.yaml — skip the entire file during initial deploy
resources:
  - helmchart.yaml
  - certificates.yaml # IGNORE INITIALLY

# In ingress.yaml — skip just this middleware during initial deploy
middlewares:
  - name: forwardauth-authelia # IGNORE INITIALLY
    namespace: base          # IGNORE INITIALLY
```

When deploying with `APPLY_MODE=initial`, lines ending in `# IGNORE INITIALLY` are deleted from all component YAML files before kustomize runs. On the second run (without `initial`), the full file is applied unchanged.

### `# PINNED`

In HelmChart or image references, add `# PINNED` on the same line to prevent the `k3s update` command from upgrading a specific chart version or image tag. Useful for pinning to a known-good version.

```yaml
spec:
  version: 0.11.5  # PINNED — do not autoupdate
```

### `# POST_APPLY`

YAML files listed in `kustomization.yaml` that are applied by a `post.sh` script (not directly by kubectl) should have `# POST_APPLY` as their first line. The validator skips orphan-file warnings for these.

```yaml
# POST_APPLY: applied by cert-manager/post.sh
---
apiVersion: cert-manager.io/v1
```

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
