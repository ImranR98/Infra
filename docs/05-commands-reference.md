# 5 &mdash; Commands Reference

All commands follow the pattern:

```
./atlas.sh <target> <command> [subcommand...] [args...]
```

## Built-in commands

### `validate`

```
./atlas.sh <target> validate
```

Validates the entire configuration for a target. Checks:

- **K3s components**: Each component directory must have a `kustomization.yaml`.
  Runs `kubectl kustomize` to verify manifests build. Checks all YAML files for
  `$VARIABLE` references that aren't in the VARS template.
- **Compose files**: Validates YAML syntax with `yq`. Checks variable references.
  If Docker is available, runs `docker compose config --dry-run`.

Output shows a summary: "K3s: OK / issues found" and "Compose: OK / issues found".

### `list-domains`

```
./atlas.sh <target> list-domains
```

Extracts all `Host(`...`)` values from Traefik IngressRoute and middleware
definitions across both compose and k3s configurations. Replaces
`$SERVICES_DOMAIN` with its actual value. Useful for DNS planning and auditing.

---

## Shared top-level commands

### `prereqs`

```
./atlas.sh <target> prereqs
```

Installs system prerequisites. This command does NOT require a VARS file to
exist (it only needs the target directory to exist for the dispatcher to
resolve the command path).

What it installs:
1. **Docker + Docker Compose plugin** &mdash; Sets up Docker CE repository,
   installs packages, enables and starts docker.service.
2. **yq** &mdash; YAML processor (`mikefarah/yq`).
3. **envsubst** &mdash; Part of gettext package.
4. **jq** &mdash; JSON processor.
5. **curl** &mdash; For downloads.
6. **python3** &mdash; For the update script.

Reports `[OK]` or `[MISSING]` for each tool at the end.

### `update`

```
./atlas.sh <target> update [--dry-run]
```

Scans for dependency updates using Renovate. Requires either the `renovate`
npm package or `npx`.

Flow:
1. Runs `renovate --platform=local` against the repo with the config from
   `renovate.json`.
2. Captures the debug log output.
3. Pipes it to `_apply_updates.py` which parses the JSON log and applies
   version updates to YAML files.
4. Checks Traefik plugin versions by querying GitHub Releases API.
5. If FRPC was updated, prints a reminder to rebuild the FRPS image.

**`--dry-run`**: Shows what would be changed without modifying files.

See [Updates and Maintenance](09-updates-and-maintenance.md) for the full
update system documentation.

### `wireguard`

```
./atlas.sh <target> wireguard <config-file>
```

Installs WireGuard and deploys a standard config file. Works with any provider
(Mullvad, ProtonVPN, self-hosted, etc.).  See the detailed entry under
[K3s commands](#wireguard) for the full description.

---

## Compose commands

### `compose install`

```
./atlas.sh <target> compose install
```

Renders templates and installs the compose stack as a systemd service.

Steps:
1. Renders `compose.yaml` with envsubst to the state directory.
2. Creates host directories for all volumes specified in the compose file.
   Sets proper ownership (uses `$MY_UID` when running as root).
3. Processes template files (`compose/templates/`).
4. Generates a systemd unit file at `/etc/systemd/system/<target>.service`
   that runs `docker compose up/down`.
5. Sets SELinux context if `chcon` is available.
6. Enables and starts the service.

The systemd unit uses `Restart=always` with a 30-second delay.

### `compose restart`

```
./atlas.sh <target> compose restart <service>
```

Restarts a single service within a compose stack. Re-renders templates and the
compose file first, then runs `docker compose down <svc>` followed by
`docker compose up -d <svc>`.

### `compose backup-state`

```
./atlas.sh <target> compose backup-state [remote] [remote-target]
```

Backs up the compose runtime state directory.

**Local mode** (no arguments, piped or interactive):
- Runs a temporary Alpine Docker container that mounts the state directory
  read-only and creates a tar archive.
- If stdout is a terminal: writes to `compose_state_backups/<target>-backup-<timestamp>.tar`.
- If stdout is piped/redirected: streams the tar to stdout (progress to stderr).
- Automatically prunes old backups based on `BACKUP_RETENTION` (default: 1).

**Remote mode** (two arguments):
- `<remote>`: SSH target in `[user@]host:path` format (path to Atlas repo on remote).
- `<remote-target>`: Target name on the remote machine.
- SSHes into the remote, runs backup-state in streaming mode, and saves the
  tar locally. Also prunes old backups of the remote target.

The backup uses `--log-driver none` to prevent Docker from writing the tar
stream to its own logs. FIFOs and sockets are excluded from the archive.

### `compose old-images`

```
./atlas.sh <target> compose old-images
```

Lists Docker images older than 60 days, sorted by age. Uses `docker images`
with `--format` to extract image name and creation timestamp.

### `compose build-frps`

```
./atlas.sh <target> compose build-frps <frps-target>
```

Builds and pushes a custom FRPS Docker image matching the FRPC version in the
current target's compose file.

Steps:
1. Reads the FRPC version from the current target's compose file.
2. Clones `github.com/ImranR98/frps-with-multiuser-docker`.
3. Builds the image tagged `imranrdev/frps-with-multiuser:v<version>`.
4. Pushes to Docker Hub.
5. Updates the FRPS target's compose file to use the new image tag.

---

## K3s commands

### `k3s setup`

```
./atlas.sh <target> k3s setup
```

Bootstraps a K3s control-plane node. **Must be run as root** (the script
auto-elevates via sudo/run0 if needed).

Steps:
1. Prompts for confirmation about fixed IP requirement.
2. Downloads and SHA256-verifies the K3s install script.
3. Writes server config to `/etc/rancher/k3s/config.yaml.d/10-server.yaml`:
   - SELinux enabled
   - kubeconfig mode 0640
   - `cluster-init: true`
   - `node-ip` &mdash; auto-detected from the default route interface
   - `flannel-iface-regex` &mdash; restricts Flannel to physical/WiFi
     interfaces, excluding VPN tunnel interfaces
   - Node labels: `hostpath-main=true`, `external-exposed=true`
4. Runs the K3s installer.
5. Creates a `kubectl` group and grants access to the invoking user.
6. Configures the host firewall (firewalld or ufw).
7. Waits up to 150 seconds for the cluster to be ready.

### `k3s join`

```
./atlas.sh <target> k3s join <client-ip> <ssh-user>
```

Joins a remote node to the K3s cluster. Must be run on the control-plane node.

Steps:
1. Reads the K3s cluster token from `/var/lib/rancher/k3s/server/token`.
2. Determines the server's internal IP from kubectl.
3. Generates an agent install script that:
   - Auto-detects the agent's physical IP and writes it to a config drop-in
   - Sets `flannel-iface-regex` to exclude VPN interfaces
   - Installs K3s as an agent, connecting to the control-plane
    - Configures the host firewall on the agent
4. Syncs the script and `lib/common.sh` to the client via rsync.
5. Executes the agent installer on the client via SSH.
6. Waits for the node to appear as Ready.

### `k3s install`

```
./atlas.sh <target> k3s install <component> [mode]
```

Deploy, delete, diff, or render a single K3s component.

**Modes:**

| Mode | Description |
|------|-------------|
| `apply` (default) | Build with kustomize, envsubst, then `kubectl apply` |
| `initial` | Same as apply but strips `# IGNORE INITIALLY` lines from YAML |
| `delete` | Runs `delete.sh` hook, then deletes HelmCharts, resources, and PVCs |
| `diff` | Shows diff between rendered manifests and cluster state |
| `yaml` | Outputs the rendered YAML to stdout |

**`initial` mode**: Some components depend on infrastructure that isn't ready
on first deploy (e.g., cert-manager CRDs for Certificate resources). YAML lines
marked with `# IGNORE INITIALLY` are stripped on initial deploy and included
on subsequent applies. The script reminds you to re-run without `initial` after
prerequisites are ready.

**`delete` mode** cleanup order:
1. Runs `delete.sh` if present (component-specific teardown).
2. Deletes HelmChart resources (with a timeout).
3. Deletes all non-PVC resources.
4. Deletes PVCs last (with timeout).
5. Patches Released PVs to remove claimRef UIDs (enabling reuse).

**Hooks**: If `prep.sh` exists, it runs before apply. If `post.sh` exists, it
runs after apply. Hooks run from the component directory.

### `k3s group`

```
./atlas.sh <target> k3s group <base|apps> [apply|initial|delete]
```

Deploys or deletes an entire group of K3s components in order (from
`groups.yaml`).

- **Apply/initial**: Iterates through components in listed order.
- **Delete**: Iterates in reverse order. Before deleting `base` group, checks
  that no Bound PVCs remain (prevents accidental data loss).

### `k3s update-node-ip`

```
./atlas.sh <target> k3s update-node-ip
```

Updates the K3s node IP after a network change.

Steps:
1. Determines the primary network interface from the default route
   (using `get_node_ip` from `lib/common.sh`).
2. Compares with the registered node IP in Kubernetes.
3. If different: writes `node-ip` to a K3s config drop-in, restarts k3s,
    waits for cluster readiness, and re-applies the `namespaces` component.

### `wireguard`

```
./atlas.sh <target> wireguard <config-file>
```

Installs WireGuard and deploys a config file.  Works with any standard
WireGuard config (Mullvad, ProtonVPN, self-hosted, etc.).

The command automatically:
- Installs `wireguard-tools` if missing.
- Rewrites `AllowedIPs` to `0.0.0.0/1, 128.0.0.0/1` so K3s subnets
  and the LAN stay on the physical NIC.
- Adds `PostUp`/`PreDown` routes for the endpoint to prevent a routing
  dead loop.
- Enables and starts `wg-quick@wg0`, which auto-connects at boot.

VPN apps (Mullvad GUI, OpenVPN client, etc.) are not recommended — export
their WireGuard config and use this command instead.
