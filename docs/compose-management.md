# Docker Compose Management

Infra wraps Compose stacks as systemd units. This doc focuses on Infra-specific conventions — not on what Compose or systemd are.

## Template rendering pipeline

A Compose target's source files live under `targets/<target>/compose/` and get rendered into `current_target/compose_live_state/` (gitignored). The pipeline:

1. `render_compose_yaml()` — runs `envsubst` on `compose.yaml`, writes result to `$COMPOSE_STATE_DIR`
2. `configure_compose_templates()` — walks `templates/`, renders each file, places result in `$COMPOSE_STATE_DIR`

Both use `$ENVSUBST_VARS` as the allowlist of variables to expand (see [variables-and-templating.md](variables-and-templating.md)).

### `.secret` / `.plain` file conventions

Files under `compose/templates/` use extension suffixes to control how they're rendered:

| Suffix | Behavior |
|--------|----------|
| `*.secret` | envsubst + `chmod 600`. Suffix stripped. For tokens, passwords, private keys. |
| `*.plain` | Copied verbatim, no envsubst. Suffix stripped. For files that must not have variable expansion. |
| Everything else | envsubst only. |

### `# IGNORE INITIALLY` bootstrap pattern

All `.secret` template files support first-time bootstrap. On the very first render (destination doesn't exist yet), lines ending with `# IGNORE INITIALLY` are commented out. This prevents services from failing on missing dependencies during initial setup. On subsequent renders, all lines are included. This is commonly used for Authelia configuration.

### Per-component `prep.sh` hooks

Each component under `templates/` can include a `prep.sh` that runs before template rendering. This is where component-specific initialization lives — for example, Traefik's `prep.sh` seeds an empty `acme.json` with `chmod 600` for Let's Encrypt certificate storage, and Authelia's `prep.sh` handles `users_database.yml` creation.

## `compose install`

```bash
./atlas.sh <target> compose install
```

Runs the rendering pipeline, creates host directories for bind-mounted volumes (with `$MY_UID` ownership), and installs a systemd unit named `<target>.service` that runs `docker compose up/down`. The Compose project name equals the target name.

Volume paths are auto-created. If a path has a file extension (e.g., `config.json`), its parent directory is created instead. On SELinux systems, the unit file gets `systemd_unit_file_t` context.

## `compose backup-state`

### Local mode

Creates a `.tar` of `current_target/compose_live_state/` via an Alpine Docker container (avoids host tar version differences; excludes FIFOs/sockets that would block reads).

### Remote mode (SSH streaming)

```bash
./atlas.sh <target> compose backup-state <user@host:path> <remote_target>
```

SSHs into a remote Infra instance and streams the tar back. The remote end sets `ATLAS_BACKUP_STREAM=true`, which makes the backup script write tar to stdout instead of a file. The local end captures stdout to disk. Old backups are pruned by `$BACKUP_RETENTION` (default: keep 1).

## `compose generate-frp-certs`

```bash
./atlas.sh <client-target> compose generate-frp-certs <server-target>
```

Generates mTLS certificates for an FRP client↔server pair. Creates a per-pair CA, a server certificate for the VPS target, and client certificates for the current target (including a preboot-specific client cert if `FRP_PREBOOT_CLIENT_CERT` is in the template). Outputs copy-paste blocks for both targets' VARS files. VARS files are never modified automatically.

## `compose restart`

```bash
./atlas.sh <target> compose restart <service-name>
```

Re-renders templates then downs/ups a single service — picks up config changes without restarting the whole stack.

## State directory lifecycle

`current_target/compose_live_state/`:
- Created on first `compose install`
- Fully gitignored (contains rendered secrets)
- Regenerated on every `compose install` or `compose restart`
- Does not exist on a fresh clone
