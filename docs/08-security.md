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

## Firewall configuration

For K3s, the host firewall (firewalld) is configured during setup:
- `cni0` interface added to trusted zone (pod network bridge).
- `flannel.1` interface added to trusted zone (overlay network VXLAN).

This is necessary because firewalld blocks forwarded traffic by default.

## Validation as security

The `validate` command catches configuration errors before deployment:
- Missing variables that would leave secrets empty
- Invalid YAML that could cause deployment failures
- `kubectl kustomize` build failures that would produce malformed manifests
- Broken `docker compose config` that would prevent containers from starting

Running `validate` after every change and before every deployment is
recommended as a safety check.
