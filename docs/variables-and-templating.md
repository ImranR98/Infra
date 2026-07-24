# Variables and Templating

## The two-file system

Atlas separates configuration into two layers:

1. **Templates** — YAML/TOML/JSON files with `$VARIABLE` placeholders. These live in `targets/` and are version-controlled.
2. **Variables** — per-target shell scripts that `export` the actual values. These live at the repo root as `VARS.<target>.sh` and are **gitignored**.

This keeps secrets out of git while making infrastructure fully defined and reproducible.

## Variable files

### Template files

`targets/<target>/VARS.template.sh` documents every variable a target needs. Each line follows the pattern:

```bash
export VARIABLE_NAME="placeholder_value"  # optional comment with generation instructions
```

The template serves as:
- Self-documenting configuration
- A source of truth for validation (what variables must exist)
- A copy-paste starting point for creating the real file

### Real variable files

`VARS.<target>.sh` at the repo root is the actual secrets file. It is sourced at runtime to populate the shell environment. If found, it takes priority over a generic `VARS.sh` (which is also supported as a fallback).

### Resolution logic

`resolve_vars_file()` in `lib/common.sh` checks:
1. `VARS.<target>.sh` — per-target secrets
2. `VARS.sh` — generic fallback

`source_env()` then validates that every variable listed in the template is present in the real file before sourcing it.

## envsubst: the rendering engine

`envsubst` (part of GNU gettext) replaces `$VARIABLE` references in text with their values from the environment. Atlas uses it for all template rendering.

### How it works

The variable list `ENVSUBST_VARS` controls which variables envsubst expands. It's built by `get_envsubst_vars()`, which collects:

- All `export`ed variables from the real vars file
- Built-in variables: `ATLAS_ROOT`, `MY_UID`, `TARGET`, `COMPOSE_STATE_DIR`, `COMPOSE_STATE_BACKUP_DIR`, `K3S_STATE_DIR`, `PVC_BACKUP_DIR`
- `DOCKER_GID` and `PROXY_IP` (when applicable)

The final format is a space-separated list with `$` prefixes: `$VAR1 $VAR2 $VAR3...`. This is passed to `envsubst` so that only known variables are expanded — any `$OTHER` reference left over after rendering indicates a missing variable, which validation catches.

## Compose template rendering

### compose.yaml rendering

`render_compose_yaml()` in `lib/common.sh` renders the target's `compose.yaml` into `current_target/compose_live_state/compose.yaml`:

```bash
envsubst "$ENVSUBST_VARS" < compose.yaml > $COMPOSE_STATE_DIR/compose.yaml
```

### Template directory rendering

`configure_compose_templates()` processes every file under `targets/<target>/compose/templates/` and places the result in `current_target/compose_live_state/`. Files are handled by extension:

| Extension | Behavior |
|-----------|----------|
| `*.plain` | Copied as-is, no envsubst. Stripped of `.plain` suffix. |
| `*.secret` | Rendered via envsubst, then `chmod 600`. Stripped of `.secret` suffix. Has `# IGNORE INITIALLY` bootstrap on first render (see below). |
| `*` (other) | Rendered via envsubst with standard behavior. |

### `# IGNORE INITIALLY` bootstrap

All `.secret` files support first-time bootstrap. On the very first render (destination doesn't exist yet), lines ending with `# IGNORE INITIALLY` are commented out. This prevents services from failing on missing dependencies during initial deployment. On subsequent renders, all lines are included.

### Per-component `prep.sh` hooks

Each component directory under `templates/` can include a `prep.sh` script. `configure_compose_templates()` runs these hooks before rendering the component's templates. This is where component-specific initialization lives — for example, Authelia's `prep.sh` handles `users_database.yml` creation, and Traefik's `prep.sh` seeds an empty `acme.json` with `chmod 600` for Let's Encrypt.

## K3s variable expansion

K3s components go through a two-stage pipeline:

1. `kubectl kustomize` builds the raw YAML from `kustomization.yaml` and referenced files
2. `envsubst "$ENVSUBST_VARS"` expands variables in the built YAML
3. The result is piped to `kubectl apply -f -`

This means `$VARIABLE` references in any K3s YAML file (HelmChart values, Secrets, ConfigMaps, IngressRoutes) are expanded just before applying to the cluster.

## Multi-line variables

Some variables contain multi-line values (e.g., Authelia user database, geoblock config, JWKS keys). These are exported as shell variables with proper quoting:

```bash
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
'
```

Indentation within these values must be preserved because they are inserted into YAML where whitespace is significant.

## Validation of variable references

The `validate` command checks every YAML file for `$VARIABLE` references that don't match any known variable. This catches typos and missing variables before deployment.

Known variables include:
- All variables from the target's `VARS.template.sh`
- Built-in variables (`MY_UID`, `TARGET`, `COMPOSE_STATE_DIR`, etc.)
- Kubernetes-specific built-ins (`NS`, `PV`, `PVC`, `VOLUMES`)

## Runtime environment variables

`atlas.sh` also sets several variables automatically:

| Variable | Source | Description |
|----------|--------|-------------|
| `ATLAS_ROOT` | Resolved from script location | Absolute path to repo root |
| `ATLAS_INTERACTIVE` | Detected from stdin | `true` if running in a terminal |
| `TARGET` | CLI argument | Name of current target |
| `COMPOSE_STATE_DIR` | Hardcoded | Path to rendered Compose state |
| `COMPOSE_STATE_BACKUP_DIR` | Hardcoded | Path for Compose state backups |
| `K3S_STATE_DIR` | Hardcoded | Path for K3s persistent storage (Longhorn) |
| `PVC_BACKUP_DIR` | Hardcoded | Path for K3s PVC backup archives |
| `MY_UID` | `id -u` | Current user's UID (1000 if root) |
| `DOCKER_GID` | `getent group docker` | Docker group GID |
| `PROXY_IP` | Resolved from `PROXY_HOST` | IP address of the FRP proxy server |

### `MY_UID` behavior

When running as root (e.g., in a systemd service), `MY_UID` is forced to `1000`. Otherwise it reflects the actual user's UID. This is used for file ownership in bind-mounted Compose volumes.

### `*_HASHABLE` → `*_HASHED` auto-hashing

Variables ending in `_HASHABLE` are automatically hashed to a corresponding `_HASHED` variable using `openssl passwd -6` (SHA-512 `$6$` format). This is used for generating password hashes from cleartext secrets at variable-load time, without storing the hash in plaintext vars files.

For example, if a vars file exports `AUTHELIA_USERS_DATABASE_HASHABLE` (containing bcrypt-compatible password hashes), the system generates `AUTHELIA_USERS_DATABASE_HASHED` with the SHA-512 equivalent. The template references the `_HASHED` version while the `_HASHABLE` source stays in the secrets file.
