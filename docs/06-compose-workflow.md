# 6 &mdash; Compose Workflow

## Overview

The Docker Compose workflow deploys services on a single host with systemd
supervision. It's used for targets that only need container orchestration
without Kubernetes, and as the infrastructure layer for K3s targets
(e.g., running an FRP client alongside a K3s cluster).

## Deployment lifecycle

```
compose install
  ├── render_compose_yaml()         # envsubst compose.yaml to state dir
  ├── create volume directories     # mkdir + chown for each volume
  ├── configure_compose_templates() # process template files
  ├── generate systemd unit         # unit that wraps docker compose
  └── systemctl enable --now        # start and auto-restart on boot
```

## Compose file rendering

The compose file at `targets/<TARGET>/compose/compose.yaml` is an envsubst
template. Variables like `$COMPOSE_STATE_DIR`, `$TARGET`, and custom VARS
are substituted at render time.

Example:

```yaml
services:
  myapp:
    image: myimage:v1.0.0
    volumes:
      - $COMPOSE_STATE_DIR/myapp/config:/app/config:ro
    network_mode: host
```

After rendering, `$COMPOSE_STATE_DIR` becomes the actual path
(`/opt/atlas/current_target/compose_live_state`).

## Template files

Files in `targets/<TARGET>/compose/templates/` are processed by
`configure_compose_templates()`. The directory structure under `templates/`
is mirrored into the state directory.

### File naming conventions

| Suffix | Behavior |
|--------|----------|
| `.secret` | envsubst-processed, then `chmod 600` |
| `.plain` | Copied directly, no substitution |
| `authelia/*` | Special handling: first-run comment-out of `# IGNORE INITIALLY` lines |
| `traefik/*` | Ensures `acme.json` exists before Traefik starts |

The `.secret` / `.plain` suffix convention separates files containing secrets
(which get restricted permissions) from plain configuration files.

### Special: Authelia first-run handling

Authelia configuration files under `templates/authelia/` receive special
treatment during the initial deployment. Lines ending with `# IGNORE INITIALLY`
are commented out on first run:

```yaml
# This line is commented out on first run  # IGNORE INITIALLY
  # becomes:
# # This line is commented out on first run  # IGNORE INITIALLY
```

This allows deploying configuration that would fail validation before
certain prerequisites exist (e.g., OIDC providers that aren't ready yet).
On subsequent `compose install` runs, all lines are processed normally.

### Special: Traefik ACME

Traefik requires the `acme.json` file to exist (even if empty) before it can
start. The template processor creates `{}` with mode 600 if the file doesn't
already exist.

## Systemd integration

Each compose target gets a systemd service unit at
`/etc/systemd/system/<TARGET>.service`.

The unit is generated dynamically and includes:

```ini
[Unit]
Description=<target> start
StartLimitIntervalSec=0

[Service]
User=<UID>
Type=simple
ExecStart=/usr/bin/docker compose -p <target> -f <state-dir>/compose.yaml up
ExecStop=/usr/bin/docker compose -p <target> -f <state-dir>/compose.yaml down
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

Key behaviors:
- Runs as the invoking user (not root), using the `User=<UID>` directive.
- `Restart=always` with a 30-second backoff ensures automatic recovery.
- `StartLimitIntervalSec=0` disables the rate limit on restarts.
- Uses the Docker Compose project name (`-p`) to namespace containers.

On SELinux systems, the unit file gets labeled with `systemd_unit_file_t`.

## Volume handling

During `compose install`, the script parses the rendered compose file with
`yq` to extract all volume mount sources. For each host path under
`$COMPOSE_STATE_DIR`:

- If the basename has a file extension (1-5 characters), it creates the parent
  directory (the path is a file).
- Otherwise, it creates the directory itself.
- When running as root, directories are chowned to `$MY_UID` (the invoking
  user's UID, or 1000 if root directly).

This ensures all volume directories exist before Docker tries to mount them.

## Backups

The `compose backup-state` command archives the entire compose state directory.
See [Commands Reference](05-commands-reference.md#compose-backup-state) for
usage.

The backup strategy:
- Creates a tar archive from inside an Alpine container (avoids Docker
  writing the tar stream to its json-file logs via `--log-driver none`).
- Excludes FIFOs and sockets (which block reads indefinitely).
- Supports both local file output and remote SSH streaming.
- Implements retention pruning based on `BACKUP_RETENTION`.

## Adding a service to a compose target

1. Add a service definition to `targets/<TARGET>/compose/compose.yaml`.
2. Add any config files under `targets/<TARGET>/compose/templates/<service>/`.
   Use `.secret` for files with secrets, `.plain` for others.
3. Add any new variables to `targets/<TARGET>/VARS.template.sh`.
4. Add actual values to `VARS.<TARGET>.sh`.
5. Run `./atlas.sh <TARGET> validate` to verify.
6. Run `./atlas.sh <TARGET> compose install` to deploy.
