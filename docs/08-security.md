# 8 &mdash; Security Model

## Overview

Atlas implements a multi-layered security model across both Compose and K3s
deployments. The K3s layer uses Kubernetes NetworkPolicies for defense in
depth, while the Compose layer relies on Docker networking and application-
level security.

## K3s security architecture

### Namespace segmentation

Components are deployed into separate Kubernetes namespaces based on their
security requirements:

| Namespace | Purpose | Pod Security |
|-----------|---------|--------------|
| `base` | Core infrastructure (cert-manager, traefik, authelia, crowdsec, ntfy) | baseline |
| `base-privileged` | Infrastructure needing host access (NFS server) | privileged |
| `apps` | User-facing applications (jellyfin, immich, nextcloud, etc.) | baseline |
| `apps-privileged` | Apps needing host access (mosquitto, opencanary) | privileged |
| `monitoring` | Observability services (logtfy) | baseline |

Each namespace has Pod Security Standards labels for audit, warning, and
enforcement. Most services run under **baseline**, which limits privileged
container features. Only services that genuinely need host-level access
(hostPath mounts, hostNetwork, hostPort) are placed in `*-privileged`
namespaces.

### NetworkPolicies: default-deny model

Every namespace starts with a **default-deny-all** policy that blocks all
ingress and egress traffic:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: base
spec:
  podSelector: {}        # all pods in the namespace
  policyTypes:
    - Ingress            # deny all incoming
    - Egress             # deny all outgoing
```

This is then selectively relaxed by additional policies.

### Baseline policies (every namespace)

Each namespace gets these common policies:

**`allow-internal-egress`** &mdash; permits three categories of outbound traffic:
1. **Pod network** (10.42.0.0/16): communication with other pods.
2. **API server subnet**: required because kube-proxy DNAT rewrites ClusterIP
   traffic to the API server's node IP *before* NetworkPolicy evaluation. The
   service CIDR alone is insufficient.
3. **All namespaces**: cross-namespace pod communication.
4. **DNS** (UDP/TCP 53): queries to CoreDNS in kube-system.

**`allow-traefik-ingress`** &mdash; allows HTTP ingress from Traefik pods in
`kube-system`. This is the only way external traffic reaches services.

**`allow-helm-egress`** (base and apps namespaces only) &mdash; allows
HelmChart install jobs to reach the internet on port 443 for downloading
Helm charts. Uses a pod selector matching `helmcharts.helm.cattle.io/chart`.
Restricts egress to non-RFC1918 addresses (public internet only).

### Component-specific policies

Components that need additional network access define their own
`network-policy.yaml`. Examples:

- **cert-manager**: Egress to the internet on ports 80 and 443 for Let's
  Encrypt ACME challenges and OCSP stapling.
- **ollama**: Egress to container registries for pulling LLM images.
- **mosquitto**: Ingress on MQTT ports from specific sources.

### Policy layering

```
┌────────────────────────────────────────┐
│          Component-specific policies    │
│          (added on top of baseline)     │
├────────────────────────────────────────┤
│     allow-helm-egress (base + apps)     │
├────────────────────────────────────────┤
│  allow-traefik-ingress (all namespaces) │
├────────────────────────────────────────┤
│  allow-internal-egress (all namespaces) │
├────────────────────────────────────────┤
│  default-deny-all (all namespaces)      │
└────────────────────────────────────────┘
```

The final policy set for any pod is the union of all matching policies.
Multiple policies targeting the same pod are additive.

## Application-level security

### Traefik as HTTPS gateway

All HTTP traffic enters through Traefik, which:
- Terminates TLS using certificates from **Let's Encrypt** via cert-manager
  (K3s) or Traefik's built-in ACME (Compose).
- Routes requests based on `Host()` rules to backend services.
- Applies middleware chains for authentication, rate limiting, and security
  headers.

### Authelia SSO/MFA

Authelia provides single sign-on and multi-factor authentication. Protected
services are configured with Traefik's `ForwardAuth` middleware, which
redirects unauthenticated users to Authelia's login portal.

Features:
- Password authentication with argon2 hashing
- OIDC provider support for external identity sources
- Per-resource access control policies
- Redis-backed session storage

### CrowdSec intrusion prevention

CrowdSec monitors logs and blocks malicious IPs at the Traefik level using a
bouncer middleware. Decisions are made by the CrowdSec LAPI (Local API) and
enforced by the bouncer.

### Geo-blocking

Traefik middleware can restrict access by country using MaxMind GeoIP data.
The list of allowed or blocked countries is configured in the VARS file via
a multi-line variable:

```bash
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'
```

### Localhost basic auth

Internal-only services (exposed only via VPN or localhost) use Traefik's
`BasicAuth` middleware with bcrypt-hashed credentials.

## Compose security model

For compose targets, security is handled at the Docker and application
layers:

- **Traefik**: Handles TLS termination and HTTP routing, same as in K3s.
- **Authelia**: Provides SSO/MFA for compose services via Traefik
  ForwardAuth.
- **Host network mode**: Some services (FRP client/server) run in
  `network_mode: host` for performance. These are minimal, locked-down
  services.
- **Read-only mounts**: Config files are mounted read-only (e.g.,
  `:ro` suffix on volumes).

## Secret management

Secrets are stored in `VARS.<target>.sh` files which are:
- Gitignored (pattern: `/VARS.*.sh` in `.gitignore`)
- `chmod 600` recommended
- Never rendered into version-controlled files

Template files with the `.secret` suffix are envsubst-processed and
automatically `chmod 600` when rendered to the state directory.

Values for secrets are typically generated using `openssl rand`, and the
generation commands are documented in the VARS template comments.

## Host firewall and VPN coexistence

**At configuration time** (`k3s setup` or `k3s join`), the host firewall is
configured to allow K3s networking. Both firewalld (RHEL/Fedora) and ufw
(Ubuntu/Debian) are supported.

### Firewall rules

**CIDRs trusted unconditionally** (assigned to firewalld `trusted` zone, or
allowed from any source with ufw):

| CIDR | Purpose |
|------|---------|
| `10.42.0.0/16` | Pod network — all inter-pod traffic |
| `10.43.0.0/16` | Service CIDR — virtual IPs for ClusterIP services |

These CIDRs are trusted rather than specific interfaces (`cni0`, `flannel.1`)
because in multi-node clusters, VXLAN-encapsulated pod traffic arrives on the
**physical NIC** before the kernel decapsulates it. Trusting only the virtual
interfaces would miss cross-node pod traffic.

**Ports opened** (in the default/firewalld zone, or unrestricted with ufw):

| Port | Protocol | Purpose |
|------|----------|---------|
| 8472 | UDP | Flannel VXLAN overlay — cross-node pod traffic |
| 6443 | TCP | K3s API server — worker → control-plane registration |
| 10250 | TCP | Kubelet API — logs, exec, metrics between nodes |
| 2379 | TCP | etcd client — for HA control-plane |
| 2380 | TCP | etcd peer replication — for HA control-plane |
| 443 | TCP | HTTPS ingress — Traefik and LAN-accessible services |

### Policy routing for VPN coexistence

Many VPN clients (Mullvad, WireGuard, OpenVPN) install a default route
and/or kill-switch rules that capture **all** traffic, breaking K3s networking.
The `configure_k3s_routing()` function, called during setup and join, installs
OS-level policy routing to protect K3s subnets:

1. Detects the physical LAN interface and subnet (e.g. `192.168.8.0/24`)
2. Adds `ip rule` entries at priority 32764–32765, which beats typical VPN
   rules (~32766), forcing pod, service, and LAN traffic through the `main`
   routing table instead of the VPN tunnel
3. Installs a systemd oneshot service (`k3s-routing.service`) that re-applies
   the rules at boot before `network-online.target`

This means pod-to-pod, pod-to-service, and inter-node traffic always stays
on the physical LAN regardless of what the VPN does with the default route.

### VPN compatibility

| VPN | Kill switch | Fix |
|-----|:-----------:|-----|
| Bare WireGuard (`wg-quick`) | None by default | Works out of the box |
| Mullvad VPN app | On by default | `mullvad lockdown-mode set off` |
| OpenVPN / other | Depends on config | Disable kill switch / block-outside-dns |

Policy routing handles the routing conflict. The kill switch is a separate
layer (iptables/nftables rules that DROP non-VPN traffic) and must be disabled
separately — policy routing alone cannot override firewall rules.

### Multi-node considerations

On a single-node cluster, all traffic stays local to the host and the firewall
rules are mostly belt-and-suspenders. On a multi-node cluster, every item above
becomes critical:

- **UDP 8472** must be open on every node — without it, Flannel VXLAN packets
  from peer nodes are dropped and cross-node pod communication fails
- **TCP 6443** must be open on server nodes — worker agents cannot register
- **TCP 10250** must be open on every node — control-plane cannot reach
  worker kubelet APIs
- **Flannel interface discovery** is restricted to physical NICs via
  `flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"`,
  preventing Flannel from accidentally binding to VPN tunnel interfaces
- **`node-ip`** is pinned to the physical LAN address, preventing the node
  from registering with the VPN IP

## Validation as security

The `validate` command catches configuration errors before deployment:
- Missing variables that would leave secrets empty
- Invalid YAML that could cause deployment failures
- `kubectl kustomize` build failures that would produce malformed manifests
- Broken `docker compose config` that would prevent containers from starting

Running `validate` after every change and before every deployment is
recommended as a safety check.
