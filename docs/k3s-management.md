# K3s Management

This doc focuses on how Atlas wraps K3s — not on what K3s, kustomize, or kubectl are.

## Component structure and conventions

Each K3s workload lives in `targets/<target>/k3s/<component>/`. The Atlas-specific conventions are:

### Directory layout

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Required. Standard kustomize resources list. |
| `*.yaml` | Manifests. Naming is by convention: `prereqs.yaml` for secrets/configmaps, `ingress.yaml` for Traefik routes, `network-policy.yaml` for pod isolation. |
| `prep.sh` | Optional. Runs before `kubectl apply`. |
| `post.sh` | Optional. Runs after `kubectl apply`. |
| `delete.sh` | Optional. Runs before the standard deletion pipeline for custom cleanup. |

### Pipeline: `kubectl kustomize` → `envsubst` → `kubectl apply`

All component YAML goes through a two-stage pipeline: kustomize builds the raw YAML, then `envsubst` expands `$VARIABLE` references before applying to the cluster. This means template variables work in any YAML file — HelmChart values, IngressRoutes, Secrets, etc.

## The `# IGNORE INITIALLY` bootstrap pattern

Atlas uses a custom two-phase bootstrap for components that depend on resources from other components. YAML lines ending with `# IGNORE INITIALLY` reference objects that won't exist yet during initial deployment (e.g., a `Certificate` referencing a `ClusterIssuer` that hasn't been deployed).

Two behaviors, depending on context:

- **K3s `initial` mode:** Lines with `# IGNORE INITIALLY` are *removed* from the built YAML before apply. The operator gets a reminder to re-run without `initial` to include them.
- **Compose Authelia bootstrap:** Lines with `# IGNORE INITIALLY` are *commented out* on first render, then included on subsequent renders.

This lets a greenfield cluster deploy partially, get dependencies up, then complete the deployment.

## Group-based deployment (`groups.yaml`)

Components are organized into ordered groups:

```yaml
base:
  - namespaces
  - nfs-server
  - csi-driver-nfs
  - cert-manager
  - traefik
  # ... more infrastructure

apps:
  - pvc-backup
  - immich
  - jellyfin
  # ... applications
```

Commands:

```bash
./atlas.sh <target> k3s group base apply      # Deploy infra in order
./atlas.sh <target> k3s group base initial    # Bootstrap with IGNORE INITIALLY
./atlas.sh <target> k3s group apps delete     # Tear down apps (reverse order)
./atlas.sh <target> k3s group base delete     # Then infra (reverse order)
```

Deploy order = listed order. Delete order = reverse. Deleting base refuses to proceed if any Bound PVCs still exist.

## Hook scripts

### `prep.sh`

Runs before manifests hit the cluster. Used for pre-creating prerequisites that the manifests declare but don't create.

### `post.sh`

Runs after apply. Most commonly waits for CRDs to become established via the Atlas helper:

```bash
source "$ATLAS_ROOT/lib/common.sh"
wait_for_crds 150 middlewares.traefik.io ingressroutes.traefik.io
```

`wait_for_crds()` polls `kubectl wait` with a configurable timeout (default 300s). This is a custom wrapper around standard kubectl for use in hooks.

### `delete.sh`

Runs before the standard deletion pipeline. The standard pipeline deletes HelmCharts first (so they can clean up managed resources), then non-PVC resources, then PVCs last (in case other resources reference them). Released PVs are patched to remove `claimRef.uid` for re-binding. If a component needs cleanup beyond that, `delete.sh` provides the hook.

## Component modes

`k3s deploy <component> <mode>` supports:

| Mode | Behavior |
|------|----------|
| `apply` | Full deploy: prep.sh → kustomize → envsubst → apply → post.sh |
| `initial` | Bootstrap: same pipeline but `# IGNORE INITIALLY` lines are stripped |
| `delete` | Teardown: delete.sh → HelmChart cleanup → resource deletion → PVC cleanup |
| `diff` | `kubectl diff` — preview changes without applying |
| `yaml` | Print rendered YAML to stdout |

## Node management commands

```
./atlas.sh <target> k3s setup                  # Bootstrap control-plane
./atlas.sh <target> k3s join <ip> <user>       # Join agent node (default)
./atlas.sh <target> k3s join <ip> <user> server  # Join additional control-plane node
./atlas.sh <target> k3s update-node-ip         # Reconfigure after IP change
```

**`setup`** — Downloads the K3s installer (with SHA256 verification against GitHub), writes config drop-ins (node IP auto-detected, SELinux on, node labels set), runs host preparation scripts (`prep-control-plane.sh` creates the NFS state directory), then runs the installer. Creates a `kubectl` group and configures the firewall.

**`join`** — Runs from the control-plane. Reads the cluster token, optionally syncs `prep-control-plane.sh` if joining as a `server`, then installs K3s agent or server via SSH. The optional third argument `[agent|server]` defaults to `agent`.

**`update-node-ip`** — Detects the node's new IP, writes a config drop-in, restarts K3s, and re-applies network policies. Uses the shared `wait_for_k3s_cluster()` helper from common.sh.

## Host preparation scripts

Atlas includes reusable host preparation scripts that run on every node during setup/join, BEFORE K3s starts.

**`prep-control-plane.sh`** — Runs on control-plane nodes only. Creates the K3s NFS state directory (`$K3S_STATE_DIR`) and pre-creates subdirectories for all persistent volumes discovered by scanning `prereqs.yaml` files. Idempotent — safe to re-run.

## Storage

All persistent volumes use NFS-backed CSI PVs served by the on-cluster NFS server. Data lives at `$K3S_STATE_DIR` on the host filesystem. See `prep-control-plane.sh` for the setup script.

## PVC backup and restore

A CronJob backs up labeled PVCs to the host filesystem. Restore is a separate Atlas command.

### Backup

The `pvc-backup` component in the `apps` group runs a nightly CronJob at 3AM. For each PVC labeled `auto-backup: "true"`, it:
1. Scales down all workloads referencing the PVC
2. Creates a temporary pod that mounts the PVC and a hostPath backup destination
3. Archives the PVC contents as a `.tar.gz` (with a `timestamp.txt` inside)
4. Deletes the temp pod and scales workloads back up

Backups are stored at `$PVC_BACKUP_DIR/<pvc-name>.tar.gz` (at `$ATLAS_ROOT/k3s_state_backups/`, gitignored). The filename is constant — each run overwrites the previous copy.

Manual trigger (zero code duplication):
```bash
kubectl create job backup-manual --from=cronjob/pvc-backup -n apps
```

### Restore

```bash
./atlas.sh <target> k3s restore-pvc <pvc-name> [-y]
```

The restore script:
1. Finds the backup archive at `$PVC_BACKUP_DIR/<name>.tar.gz`
2. Discovers all workloads using the PVC
3. Prompts for confirmation (skipped with `-y`)
4. Scales workloads to 0, extracts the archive into the PVC via a temp pod, scales back up

