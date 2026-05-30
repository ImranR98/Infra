# 3 &mdash; Architecture

## Entry point: `atlas.sh`

The main entry point (`atlas.sh:1-62`) performs these steps in order:

1. **Sets strict mode**: `set -euo pipefail` &mdash; exit on error, undefined
   variable, or pipeline failure.

2. **Determines ATLAS_ROOT**: Resolves the repository directory from the
   script's own location, no matter where it's invoked from.

3. **Detects interactivity**: Sets `ATLAS_INTERACTIVE` to `true` if stdin is a
   terminal. This affects the choice of `sudo` vs `run0` (run0 is non-interactive
   by default on Fedora Atomic).

4. **Exports state directories**:
   - `COMPOSE_STATE_DIR` &rarr; `current_target/compose_live_state/`
   - `COMPOSE_STATE_BACKUP_DIR` &rarr; `compose_state_backups/`
   - `LONGHORN_BACKUP_DIR` &rarr; `current_target/k3s_longhorn_backups/`

5. **Validates the target**: Checks that `targets/$1` exists.

6. **Sources `lib/common.sh`**: Loads all utility functions.

7. **Loads VARS**: Calls `resolve_vars_file()` to find `VARS.<target>.sh` (or
   `VARS.sh` as fallback), validates that all template variables are present,
   sources the file, and builds `ENVSUBST_VARS` (a space-separated list of
   `$VARNAME`s for envsubst).

8. **Checks for Docker**: If a compose or k3s command is being run, verifies
   Docker is available and exports `DOCKER_GID`.

9. **Sources `lib/dispatch.sh`** and calls `atlas_dispatch "$@"`.

## Command dispatch: `lib/dispatch.sh`

The dispatcher (`lib/dispatch.sh:1-71`) resolves commands with a two-tier
search strategy:

### Priority order

1. **Target-specific commands**: `targets/<TARGET>/commands/` &mdash; checked first.
2. **Shared commands**: `commands/` &mdash; checked second.

### Resolution algorithm

For each argument in the command line:

1. Look for `<search_path>/<arg>.sh` (executable bash script).
2. Look for `<search_path>/<arg>.py` (Python script, run with `python3`).
3. Look for `<search_path>/<arg>/` (a directory &mdash; continue traversing for
   nested subcommands).

The first match wins. If nothing matches, `_atlas_help` lists available commands.

### Built-in commands

Two commands are handled directly in the dispatcher before the search begins:

- `validate` &rarr; calls `validate()` from `common.sh`
- `list-domains` &rarr; calls `list_domains()` from `common.sh`

### Help display

When no command is given (or an unknown command), the help shows:
- Top-level `commands/*.sh` scripts with their `# DESC:` annotations
- Subcommands under `commands/compose/` and `commands/k3s/` (only if the target
  has that directory)

## Library: `lib/common.sh`

This is the core utility library, sourced exactly once (guarded by
`ATLAS_LIB_LOADED`). It provides five groups of functions:

### Package management (lines 8-66)

| Function | Description |
|----------|-------------|
| `get_sudo_cmd()` | Returns `run0` (if available and non-interactive) or `sudo` |
| `detect_pkgmgr()` | Returns `apt`, `dnf`, `rpm-ostree`, or `unknown` |
| `install_pkgs()` | Installs packages using the detected package manager |
| `ensure_docker_repo()` | Sets up the Docker CE repository (handles apt keyrings, dnf config-manager) |

### Variable management (lines 68-131)

| Function | Description |
|----------|-------------|
| `resolve_vars_file()` | Finds `VARS.<target>.sh` or falls back to `VARS.sh` |
| `get_template_export_names()` | Extracts `export VARNAME` lines from the template |
| `source_env()` | Validates all template vars exist in the VARS file, then sources it |
| `get_envsubst_vars()` | Builds the envsubst variable list (`$VAR1 $VAR2 ...`) |
| `ensure_envsubst_vars()` | Sets `ENVSUBST_VARS` if not already set |

### Compose generation (lines 133-172)

| Function | Description |
|----------|-------------|
| `render_compose_yaml()` | Substitutes variables into `compose.yaml`, writes to state dir |
| `configure_compose_templates()` | Processes all files in `compose/templates/` |

Template processing rules in `configure_compose_templates()`:
- **`.plain` files**: Copied directly, no substitution.
- **`.secret` files**: envsubst-processed, then `chmod 600`.
- **`authelia/*` files**: Special handling. On first run, lines with
  `# IGNORE INITIALLY` are commented out; on subsequent runs, processed normally.
  Also writes the Authelia users database YAML.
- **`traefik/*` files**: Ensures `acme.json` exists (needed before Traefik starts).

### K3s utilities (lines 174-205)

| Function | Description |
|----------|-------------|
| `download_k3s_installer()` | Downloads and SHA256-verifies the K3s install script |
| `configure_firewall()` | Adds `cni0` and `flannel.1` interfaces to firewalld trusted zone |

### Validation (lines 207-323)

| Function | Description |
|----------|-------------|
| `_build_known_vars()` | Builds set of known variables (from template + builtins) |
| `_check_var_refs()` | Scans a YAML file for `$VAR` references not in the known set |
| `validate()` | Top-level orchestrator; runs K3s and Compose validation |
| `_validate_k3s()` | Checks each component's kustomization.yaml, runs `kubectl kustomize`, checks var refs |
| `_validate_compose()` | Checks YAML syntax with `yq`, checks var refs, runs `docker compose config` |

### Other utilities (lines 325-364)

| Function | Description |
|----------|-------------|
| `list_domains()` | Extracts `Host(`...`)` values from Traefik configs across compose and k3s |
| `wait_for_crds()` | Polls `kubectl wait` for CRD establishment status |

## Data flow

```
VARS.<target>.sh (secrets)
        │
        ▼
    source_env() ── validates, sources, exports
        │
        ▼
    ENVSUBST_VARS (list of $VAR names)
        │
        ▼
    envsubst "$ENVSUBST_VARS"
        │
        ├── compose.yaml ──► rendered compose.yaml
        │
        ├── templates/* ──► rendered config files
        │
        └── k3s/**/*.yaml ──► kubectl kustomize ──► envsubst ──► kubectl apply
```

## State management

Runtime state is stored under `current_target/` (gitignored):

- `current_target/compose_live_state/` &mdash; Rendered compose files and configs
- `current_target/k3s_longhorn_backups/` &mdash; Longhorn backup data

Backup archives are stored in `compose_state_backups/` (also gitignored).

The `COMPOSE_STATE_DIR` is the working directory for compose stacks. The systemd
service file references the rendered `compose.yaml` from this path.
