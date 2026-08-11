# Commands and Dispatch

## The dispatch system

`infra.sh` delegates all command routing to `infra_dispatch()` in `lib/dispatch.sh`. This function takes the remaining arguments after the target name and resolves them to an executable script.

Before any command runs, `infra.sh` checks the machine's hostname against the target name. If they don't match, it prints a warning and (when stdin is a terminal) waits for the user to press Enter before continuing. When running non-interactively the warning is printed but the prompt is skipped.

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

Two commands bypass the script resolution entirely and are handled directly in `infra_dispatch()`:

- **`validate`** — runs YAML validation, kustomize build checks, variable reference checks
- **`list-domains`** — extracts all `Host(...)` domains from IngressRoutes and Compose rules

### Help system

If no matching script is found, or if the user provides no arguments, a help screen is generated automatically. It lists:

- Built-in commands
- Top-level scripts from `commands/*.sh` with their `# DESC:` descriptions
- Subcommand scripts under `commands/compose/` and `commands/k3s/`

## How commands work

Every command script:
1. Runs with the remaining CLI arguments after the target and subcommand path
2. Has access to `$INFRA_ROOT`, `$TARGET`, and all variables from `VARS.<target>.sh`
3. Sources `lib/common.sh` if it needs shared functions
4. Uses `get_sudo_cmd()` when root privileges are needed

### The DESC convention

The second line of each `.sh` command file starts with `# DESC:` followed by a human-readable description. This is what the help system displays.

### Boilerplate

```bash
#!/bin/bash
# DESC: Short description of what it does
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
# ... implementation ...
```

Create scripts at `commands/<name>.sh` (or `commands/<subdir>/<name>.sh` for subcommands). For target-specific commands, place them at `targets/<target>/commands/` — the dispatch router checks there first.

### Bash sourcing behavior

Commands are sourced, not executed in a subshell. This means `exit` will kill the parent shell and the script has access to all shell state from `infra.sh`. Both `.sh` (bash, must be `chmod +x`) and `.py` (python3, no chmod needed) are supported.

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
| `compose install` | Render templates, start Compose stack via `docker compose up -d` |
| `compose backup-state` | Backup Compose runtime state (local file or remote via SSH) |
| `compose generate-mtls-certs <target>` | Generate mTLS certificates for a client↔server pair |
| `compose restart <service>` | Restart a specific Compose service |

### K3s subcommands

| Command | Description |
|---------|-------------|
| `k3s setup` | Bootstrap a K3s control-plane node |
| `k3s join <ip> <user>` | Join a remote agent node via SSH |
| `k3s deploy <component> [mode]` | Deploy, delete, diff, or render a K3s component |
| `k3s group <base\|apps> [mode]` | Deploy or delete a group of components |
| `k3s update-node-ip` | Update K3s node IP after a network change |
| `k3s test-storage <size>` | Run a smoke test: create NFS PV+PVC, write/read data, clean up |
| `k3s restore-pvc <name> [-y]` | Restore a PVC from a backup archive |
| `k3s test services` | (srv0 only) Browser-based integration test for all exposed services |

## Target-specific overrides

A target can override any global command by providing a script at the corresponding path under `targets/<target>/commands/`. The override script can:

- Completely replace the global behavior
- Source the global script and extend it
- Add target-specific setup before/after calling the global script

Example: `targets/srv0/commands/compose/install-preboot.sh` installs preboot FRPC + dracut-crypt-ssh in srv0's initramfs, tunneling SSH through the FRP server for remote LUKS unlock, while `targets/bigpc/commands/compose/install-preboot.sh` installs only crypt-ssh (dropbear listening on port 8887) for direct LAN unlock — setups that only make sense when the root disk is LUKS-encrypted.
