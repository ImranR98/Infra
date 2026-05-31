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
  - cert-manager
  - traefik
  # ... infrastructure

apps:
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

`k3s install <component> <mode>` supports:

| Mode | Behavior |
|------|----------|
| `apply` | Full deploy: prep.sh → kustomize → envsubst → apply → post.sh |
| `initial` | Bootstrap: same pipeline but `# IGNORE INITIALLY` lines are stripped |
| `delete` | Teardown: delete.sh → HelmChart cleanup → resource deletion → PVC cleanup |
| `diff` | `kubectl diff` — preview changes without applying |
| `yaml` | Print rendered YAML to stdout |

## Node management commands

```
./atlas.sh <target> k3s setup              # Bootstrap control-plane
./atlas.sh <target> k3s join <ip> <user>   # Join agent via SSH
./atlas.sh <target> k3s update-node-ip     # Reconfigure after IP change
```

**`setup`** — Downloads the K3s installer (with SHA256 verification against GitHub), writes config drop-ins (node IP auto-detected, SELinux on, node labels set), runs the installer, creates a `kubectl` group, and configures the firewall (supports both firewalld and ufw).

**`join`** — Runs from the control-plane. Reads the cluster token, generates an installer script bundled with `lib/common.sh` (so the agent can use Atlas functions), syncs everything to the remote agent via rsync, and runs the installer over SSH.

**`update-node-ip`** — Detects the node's new IP (from the default route interface), compares it to the current Kubernetes node address, writes a config drop-in, restarts K3s, and re-applies network policies.

