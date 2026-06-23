# Commands and Dispatch

## The dispatch system

`atlas.sh` delegates all command routing to `atlas_dispatch()` in `lib/dispatch.sh`. This function takes the remaining arguments after the target name and resolves them to an executable script.

### Resolution order

For each argument in the command string, dispatch searches two directories (in order):

1. `targets/<target>/commands/` — target-specific override
2. `commands/` — global default

It supports nested subcommands by walking through directory levels. For example, `k3s group base apply` resolves as:

```
arg "k3s"   →  commands/k3s/ (directory, continue)
arg "group" →  commands/k3s/group.sh (script found!)
```

The remaining arguments (`base`, `apply`) are passed to the script.

### Script types

Both `.sh` (bash) and `.py` (python3) scripts are supported. Bash scripts must be executable (`chmod +x`). Python scripts just need to exist as a regular file.

### Built-in commands

Two commands bypass the script resolution entirely and are handled directly in `atlas_dispatch()`:

- **`validate`** — runs YAML validation, kustomize build checks, variable reference checks
- **`list-domains`** — extracts all `Host(...)` domains from IngressRoutes and Compose rules

### Help system

If no matching script is found, or if the user provides no arguments, a help screen is generated automatically. It lists:

- Built-in commands
- Top-level scripts from `commands/*.sh` with their `# DESC:` descriptions
- Subcommand scripts under `commands/compose/` and `commands/k3s/`

## How commands work

Every command script:
1. Is sourced/executed with the remaining CLI arguments
2. Has access to `$ATLAS_ROOT`, `$TARGET`, and all variables from `VARS.<target>.sh`
3. Sources `lib/common.sh` if it needs shared functions
4. Uses `get_sudo_cmd()` when root privileges are needed

### The DESC convention

The second line of each `.sh` command file starts with `# DESC:` followed by a human-readable description. This is what the help system displays.

## Available commands

### Top-level commands

| Command | Description |
|---------|-------------|
| `prereqs` | Install system prerequisites (Docker, yq, envsubst, jq, python3) |
| `update` | Scan for and apply dependency updates via Renovate |
| `wireguard <config>` | Install WireGuard and deploy a config file |

### Compose subcommands

| Command | Description |
|---------|------------|
| `compose install` | Render templates, install systemd service, start Compose stack |
| `compose backup-state` | Backup Compose runtime state (local file or remote via SSH) |
| `compose build-frps <target>` | Build and push the frps-with-multiuser Docker image |
| `compose restart <service>` | Restart a specific Compose service |
| `compose old-images` | List Docker images older than 60 days |

### K3s subcommands

| Command | Description |
|---------|-------------|
| `k3s setup` | Bootstrap a K3s control-plane node |
| `k3s join <ip> <user>` | Join a remote agent node via SSH |
| `k3s install <component> [mode]` | Deploy, delete, diff, or render a K3s component |
| `k3s group <base\|apps> [mode]` | Deploy or delete a group of components |
| `k3s update-node-ip` | Update K3s node IP after a network change |

## Writing a new command

1. Create a bash script at `commands/<name>.sh` (or `commands/<subdir>/<name>.sh` for subcommands)
2. Start the file with:
   ```bash
   #!/bin/bash
   # DESC: Short description of what it does
   set -euo pipefail
   source "$ATLAS_ROOT/lib/common.sh"
   ```
3. At the end, `exec` the script with `"$@"` to receive remaining arguments

If the command should be available only on specific targets, place it in `targets/<target>/commands/` instead. The dispatch router checks that location first.

## Target-specific overrides

A target can override any global command by providing a script at the corresponding path under `targets/<target>/commands/`. The override script can:

- Completely replace the global behavior
- Source the global script and extend it
- Add target-specific setup before/after calling the global script

Example: `targets/srv0/commands/compose/install-preboot.sh` is a srv0-specific command for installing FRPC/dracut-crypt-ssh in the initramfs — a setup that only makes sense when the root disk is LUKS-encrypted.
