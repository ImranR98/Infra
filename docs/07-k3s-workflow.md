# 7 &mdash; K3s Workflow

## Overview

The K3s workflow orchestrates a lightweight Kubernetes cluster on Linux
hosts. Targets with a `k3s/` directory run Kubernetes workloads organized
into deployment groups. See [Targets](04-targets.md) for the full component
model.

## Cluster bootstrapping

### `k3s setup` &mdash; control-plane initialization

The `k3s setup` command creates a single-node K3s cluster:

1. Downloads and verifies the official K3s install script (SHA256 check
   from GitHub).
2. Writes server configuration drop-ins to
   `/etc/rancher/k3s/config.yaml.d/10-server.yaml`. This includes:
   - `selinux: true` and `write-kubeconfig-mode: "0640"`
   - `cluster-init: true` (embedded etcd for single-node or HA)
   - `node-ip` &mdash; auto-detected from the default route interface
   - `flannel-iface-regex` &mdash; restricts Flannel to physical/WiFi
     interfaces (`eth`, `ens`, `enp`, `wlan`, `wlp`, etc.), preventing
     accidental binding to VPN tunnel interfaces like `wg0` or `tun0`
3. Runs the K3s installer, which:
   - Installs the `k3s` systemd service
   - Starts kubelet, containerd, and all core components
   - Sets up Flannel for pod networking
   - Configures CoreDNS for cluster DNS
4. Creates a `kubectl` Unix group for RBAC access to the cluster
   kubeconfig.
5. Configures the host firewall (firewalld or ufw) to trust pod and service
   CIDRs and open required K3s ports. See [Host firewall and VPN
   coexistence](08-security.md#host-firewall-and-vpn-coexistence) for details.
.

### `k3s join` &mdash; adding worker nodes

To add additional nodes to the cluster, run `k3s join` from the control-plane:

```
./atlas.sh myhost k3s join 192.168.1.50 myuser
```

This script:
1. Reads the K3s cluster token from `/var/lib/rancher/k3s/server/token`.
2. Generates an agent install script dynamically that:
   - Auto-detects the agent's physical IP and writes it as
     `node-ip` to a K3s config drop-in (`50-agent.yaml`).
   - Sets `flannel-iface-regex` to exclude VPN interfaces.
   - Installs K3s as an agent, connecting to the control-plane via `6443`.
    - Configures the host firewall on the agent node.
3. Syncs the script and `lib/common.sh` to the remote node via rsync.
4. SSHes into the remote node and executes the agent installer.
5. Waits for the remote node to register as Ready in `kubectl get nodes`.

## Component structure

Each K3s component is a directory under `targets/<TARGET>/k3s/<name>/`
containing a standard set of files:

### Required files

**`kustomization.yaml`** &mdash; Standard Kustomize resource list that
declares which YAML files to include:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmchart.yaml
  - prereqs.yaml
  - ingress.yaml
  - network-policy.yaml
```

### Common YAML files

**`<component>.yaml`** &mdash; The main deployment manifest. Can be any
Kubernetes resource: Deployment, StatefulSet, Service, ConfigMap, etc.
All YAML is envsubst-processed after kustomize build.

**`helmchart.yaml`** &mdash; For Helm-deployed components. Uses the
`helm.cattle.io/v1` HelmChart CRD (built into K3s):

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: base
spec:
  chart: cert-manager
  repo: https://charts.jetstack.io
  targetNamespace: base
  version: 1.20.2
  valuesContent: |-
    installCRDs: true
    resources: ...
```

Components using HelmCharts: cert-manager, longhorn, immich.

**`prereqs.yaml`** &mdash; Resources that must exist before the main
deployment: Namespaces, Secrets, PersistentVolumeClaims, etc.

**`ingress.yaml`** &mdash; Traefik IngressRoute definitions for HTTP
routing. Uses `Host()` rule syntax:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
spec:
  routes:
    - match: Host(`service.$SERVICES_DOMAIN`)
```

**`network-policy.yaml`** &mdash; Kubernetes NetworkPolicy rules
specific to this component. These augment the baseline policies defined
in `namespaces/base-policies.yaml`.

### Optional hooks

**`prep.sh`** &mdash; Runs BEFORE kubectl apply. Used for setup tasks
like creating directories, preparing secrets, or running pre-deployment
commands.

**`post.sh`** &mdash; Runs AFTER kubectl apply. Used for post-deployment
tasks like waiting for CRDs, applying additional configuration, or
sending notifications.

**`delete.sh`** &mdash; Custom teardown logic that runs BEFORE kubectl
delete. Used when resources can't be cleanly deleted by kubectl alone
(e.g., Longhorn's admission webhook/CRD circular dependency).

## Deployment pipeline

### `k3s install <component> apply` (default)

```
┌─────────────┐
│  prep.sh    │  (optional hook)
└──────┬──────┘
       ▼
┌──────────────────┐
│ kubectl kustomize│  (build manifests)
└──────┬───────────┘
       ▼
┌──────────┐
│ envsubst │  (substitute variables)
└──────┬───┘
       ▼
┌────────────────┐
│ kubectl apply  │
└──────┬─────────┘
       ▼
┌──────────┐
│ post.sh  │  (optional hook)
└──────────┘
```

### Initial vs normal deploy

Some resources can't be created on a fresh cluster because their
dependencies don't exist yet. For example, cert-manager Certificate
resources require the cert-manager CRDs to be installed first.

Atlas handles this with the `# IGNORE INITIALLY` annotation. Lines in
any YAML file ending with this comment are:

- **Stripped** during `initial` mode deployment
- **Included** during normal `apply` mode deployment

```
schedule: "0 3 * * *"  # IGNORE INITIALLY
```

This line would be removed on initial deploy and included on subsequent
applies.

The `initial` reminder: after running with `initial`, the script prints a
reminder to re-run without `initial` once prerequisites are ready.

### Deletion order

```
┌──────────────┐
│  delete.sh   │  (custom teardown, optional)
└──────┬───────┘
       ▼
┌──────────────────┐
│ kubectl delete   │  (HelmCharts first, with timeout)
│ helmchart        │
└──────┬───────────┘
       ▼
┌──────────────────┐
│ kubectl delete   │  (all non-PVC resources)
│ -f -             │
└──────┬───────────┘
       ▼
┌──────────────────┐
│ kubectl delete   │  (PVCs last, with timeout)
│ pvc              │
└──────┬───────────┘
       ▼
┌──────────────────┐
│ kubectl patch pv │  (remove claimRef UIDs from Released PVs)
└──────────────────┘
```

PVCs are deleted last because pods may still be terminating and holding
references. Released PVs are patched to remove the claimRef UID, which
makes them available for rebinding.

## Group deployment

Groups are defined in `targets/<TARGET>/k3s/groups.yaml`:

```yaml
base:
  - namespaces
  - nfs-server
  - csi-driver-nfs
  - longhorn
  - cert-manager
  - traefik
  - crowdsec
  - authelia
  - ntfy
apps:
  - immich
  - logtfy
  - jellyfin
  # ...
```

### `k3s group <group> apply`

Iterates through components in the listed order, calling
`k3s install <component> apply` for each. This ensures dependencies are
deployed before dependents (e.g., cert-manager before resources that
need Certificate CRDs).

### `k3s group <group> delete`

Iterates in reverse order. Pre-deletion guards:
- Before deleting `apps`: no checks needed.
- Before deleting `base`: checks that no Bound PVCs exist anywhere in
  the cluster. This prevents accidental deletion of storage infrastructure
  while data volumes are still in use.

### `k3s group <group> initial`

Same as apply but passes `initial` mode to each component, stripping
`# IGNORE INITIALLY` lines.

## K3s-specific environment variables

During K3s component deployment, `k3s install` exports additional
environment variables:

| Variable | Source | Description |
|----------|--------|-------------|
| `K8S_API_SERVER_IP` | kubectl | The Kubernetes API server's IP address |
| `K8S_API_SERVER_SUBNET` | Derived from above | API server IP with last octet set to `.0/24` |

These are available in YAML templates and are critical for NetworkPolicy
definitions that need to egress to the API server.

## Node IP management

K3s is sensitive to IP address changes. If a node's IP changes:

1. Run `k3s update-node-ip` to detect the change.
2. Writes a K3s config drop-in with the new `node-ip`.
3. Restarts k3s.
4. Re-applies the `namespaces` component to update NetworkPolicy rules
   that reference the API server subnet.

## Example: Deploying a new K3s cluster

```bash
# 1. Bootstrap the cluster
./atlas.sh myhost k3s setup

# 2. Deploy base infrastructure (initial mode)
./atlas.sh myhost k3s group base initial

# 3. Wait for cert-manager CRDs, Longhorn webhooks, etc.
#    (monitor with kubectl get pods -A)

# 4. Re-deploy base (normal mode) to include previously skipped resources
./atlas.sh myhost k3s group base apply

# 5. Deploy applications
./atlas.sh myhost k3s group apps apply

# 6. Optionally deploy a VPN alongside K3s
./atlas.sh myhost wireguard ~/my-vpn.conf
```
