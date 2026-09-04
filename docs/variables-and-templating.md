# Variables and Templating

## The two-file system

Infra separates configuration into two layers:

1. **Templates** — YAML/TOML/JSON files with `$VARIABLE` placeholders. These live in `targets/` and are version-controlled.
2. **Variables** — per-target shell scripts that `export` the actual values. These live in `secrets/VARS.<target>.sh` and are **gitignored** (root `VARS.<target>.sh` is also supported as a fallback).

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

`VARS.<target>.sh` in the `secrets/` directory is the actual secrets file (root is also checked as a fallback). It is sourced at runtime to populate the shell environment. If found, it takes priority over a generic `VARS.sh` (which is also supported as a fallback).

### Resolution logic

`resolve_vars_file()` in `lib/common.sh` checks:
1. `secrets/VARS.<target>.sh` — per-target secrets (root `VARS.<target>.sh` checked as fallback)
2. `secrets/VARS.sh` — generic fallback (root `VARS.sh` checked as fallback)

`source_env()` then validates that every variable listed in the template is present in the real file before sourcing it.

## envsubst: the rendering engine

`envsubst` (part of GNU gettext) replaces `$VARIABLE` references in text with their values from the environment. Infra uses it for all template rendering.

### How it works

The variable list `ENVSUBST_VARS` controls which variables envsubst expands. It's built by `get_envsubst_vars()`, which collects:

- All `export`ed variables from the real vars file
- Built-in variables: `INFRA_ROOT`, `MY_UID`, `TARGET`, `COMPOSE_STATE_DIR`, `COMPOSE_STATE_BACKUP_DIR`, `K3S_STATE_DIR`, `PVC_BACKUP_DIR`
- `DOCKER_GID` and `PROXY_IP` (when applicable)

The final format is a space-separated list with `$` prefixes: `$VAR1 $VAR2 $VAR3...`. This is passed to `envsubst` so that only known variables are expanded — any `$OTHER` reference left over after rendering indicates a missing variable, which validation catches.

## Compose template rendering

### compose.yaml rendering

`render_compose_yaml()` in `lib/compose.sh` renders the target's `compose.yaml` into `current_target/compose_live_state/compose.yaml`. If the optional gitignored `compose.private.yaml` exists, it is rendered the same way and merged over the main file with `docker compose -f ... config`:

```bash
envsubst "$ENVSUBST_VARS" < compose.yaml > $COMPOSE_STATE_DIR/compose.main.yaml
[ -f compose.private.yaml ] && envsubst "$ENVSUBST_VARS" < compose.private.yaml > $COMPOSE_STATE_DIR/compose.private.yaml
docker compose -f $COMPOSE_STATE_DIR/compose.main.yaml -f $COMPOSE_STATE_DIR/compose.private.yaml config > $COMPOSE_STATE_DIR/compose.yaml
```

### Template directory rendering

`configure_compose_templates()` processes every file under `targets/<target>/compose/templates/` and places the result in `current_target/compose_live_state/`. Files are handled by extension:

| Extension | Behavior |
|-----------|----------|
| `*.plain` | Copied as-is, no envsubst. Stripped of `.plain` suffix. |
| `*.secret` | Rendered via envsubst, then `chmod 600`. Stripped of `.secret` suffix. |
| `*` (other) | Rendered via envsubst with standard behavior. |

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

`infra.sh` also sets several variables automatically:

| Variable | Source | Description |
|----------|--------|-------------|
| `INFRA_ROOT` | Resolved from script location | Absolute path to repo root |
| `INFRA_INTERACTIVE` | Detected from stdin | `true` if running in a terminal |
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

Variables ending in `_HASHABLE` are automatically hashed to a corresponding `_HASHED` variable using `openssl passwd -6` (SHA-512 `$6$` crypt format). The value of the `_HASHABLE` variable is piped through `openssl passwd -6 -stdin`, and the resulting `$6$...` hash is exported as the `_HASHED` variable. This is typically used when a template needs an SHA-512 password hash but the vars file already stores the secret in a different format (e.g., bcrypt, cleartext, or a token).

For example, if a vars file exports `AUTHELIA_USERS_DATABASE_HASHABLE` (containing the bcrypt-hashed user database), the system generates `AUTHELIA_USERS_DATABASE_HASHED` — a single SHA-512 crypt hash of the entire database string. The template references the `_HASHED` variable while the `_HASHABLE` source stays in the secrets file.

### Structural `$VARIABLE` placeholders

Some template variables expand to multi-line YAML blocks at indented positions — for example, `$GEOBLOCK_CONFIG_SUBSET` inserts additional `countries:` / `allowUnknownCountries: false` / etc. into a middleware config. These are "structural" variables because they contribute YAML syntax, not just scalar values.

Template files containing bare `$VARIABLE` lines at mapping indentation (no `key:` prefix) fail standard `yq eval` YAML syntax checks because the unexpanded placeholder is invalid YAML. The `validate` command detects this pattern and downgrades it to a warning: *"YAML syntax skipped (structural `$VARIABLE` placeholder)"*. Other validation (variable references, kustomize build, compose config) still runs normally.
