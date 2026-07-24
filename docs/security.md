# Security

Infra takes a defense-in-depth approach to security across the stack: file permissions, encryption-at-rest, authentication middleware, intrusion prevention, and network-level access control.

## Secret management

### Separation of secrets from code

Secrets never enter git. The convention:
- `VARS.template.sh` files in each target directory list required variables with placeholder values — these are committed
- `VARS.<target>.sh` files at the repo root contain actual secrets — these are gitignored

The repo's `.gitignore` includes:
```
/VARS.sh
/VARS.*.sh
```

### Template file permissions

Template files under `compose/templates/` use file extensions to control rendering:

- **`.secret` files** — rendered via `envsubst`, then `chmod 600` (owner read/write only). Stripped of `.secret` suffix.
- **`.plain` files** — copied without `envsubst` processing (no variable expansion). Used for files that must not be modified by templating.
- **`traefik/acme.json`** — TLS certificate private keys. Seeded as `{}` with `chmod 600` if missing.

The runtime state directory (`current_target/compose_live_state/`) is fully gitignored since it contains rendered secrets.

## LUKS full-disk encryption

### Detection

`check_root_luks.sh` determines whether the root filesystem is on a LUKS-encrypted device by:
1. Finding the root block device via `findmnt`
2. Tracing device dependencies with `lsblk -s` to detect `crypt` type devices

### Remote unlock with preboot FRPC

When LUKS is detected, the srv0-specific `compose install-preboot` command sets up an SSH server and FRP client in the initramfs. This enables remote LUKS passphrase entry:

1. **dracut-crypt-ssh** embeds an SSH server in the initramfs that listens for connections before the root filesystem is available
2. **frpc-preboot** embeds an FRP client in the initramfs that tunnels SSH (port 8887) through the FRP server
3. On boot, the operator connects to the FRP server on port 8887, which tunnels to the initramfs SSH
4. The operator provides the LUKS passphrase via SSH, the root unlocks, and boot continues

This is critical for unattended reboots of an encrypted server without physical access.

## Application-layer security

### Authelia SSO and 2FA

Authelia provides centralized authentication for all web services:
- Single sign-on across all protected applications
- Two-factor authentication (TOTP/WebAuthn)
- Two authentication modes:
  - **forward-auth** — full OIDC redirect flow with 2FA (used for web apps)
  - **basic-auth** — HTTP basic auth with Authelia credentials (used for API clients)
- Access control policies based on user, group, and resource

### CrowdSec intrusion prevention

CrowdSec provides real-time threat detection:
- **LAPI (Local API)** — the CrowdSec agent that parses logs and maintains ban decisions
- **AppSec** — web application firewall component
- **bouncer** — Traefik middleware plugin that queries the LAPI for ban decisions in streaming mode

When an IP is banned by CrowdSec, the bouncer middleware blocks it at the ingress layer before it reaches any application.

### Geoblock

A Traefik middleware plugin (`geoblock`) restricts access by country of origin using the free geojs.io geolocation API. It operates in allowlist mode — only requests from configured countries are permitted. This blocks a large percentage of automated attack traffic.

### Network policies

Kubernetes NetworkPolicies isolate pods:
- Each K3s component can define a `network-policy.yaml` restricting ingress/egress traffic
- Baseline policies (`base-policies.yaml` in the `namespaces` component) apply cluster-wide defaults
- Only explicitly allowed traffic flows between namespaces and pods

### LAN whitelist middleware

A Traefik IP whitelist middleware restricts access to private IP ranges:
- `lan-whitelist` — allows `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- `cluster-only` — allows only K3s pod network (`10.42.0.0/16`), effectively localhost on a single-node cluster

These are attached to IngressRoutes that should only be accessible from the local network or within the cluster.

## Docker security

### Socket proxy

Targets that run Docker Compose expose the Docker socket through `wollomatic/socket-proxy` containers instead of mounting `/var/run/docker.sock` directly. This limits what API endpoints services can call:
- **dockerproxy** — read-only access to container listing and events (for Traefik and monitoring)
- **dockerproxy_priv** — read-write access to containers and images (for Watchtower auto-updater)

Both proxies run with minimal capabilities (`cap_drop: ALL`), read-only root filesystems, and memory limits.

### Container hardening

Compose services typically use:
- `cap_drop: ALL` to drop all capabilities
- `security_opt: no-new-privileges` to prevent privilege escalation
- `read_only: true` for stateless containers
- `mem_limit` for resource constraints
- Non-root users where supported by the image

## SSH security

- The join command uses temporary SSH connections that don't leave persistent credentials
- The backup-state remote mode uses one-shot SSH sessions (`ssh -T`)
- Preboot FRPC uses a separate client certificate for credential isolation
- FRP tunnel authentication uses mutual TLS with per-pair CAs and X.509 certificates

## TLS / Let's Encrypt

- **cert-manager** automates TLS certificate issuance and renewal for K3s IngressRoutes
- **ClusterIssuer** resources configure Let's Encrypt with HTTP-01 and DNS-01 challenges
- **Traefik** terminates TLS at the edge with auto-renewed certificates
- The `acme.json` file storing certificate private keys is `chmod 600`

## Password and key generation

The `VARS.template.sh` files include comments with generation commands for each secret:

```bash
export FRP_CLIENT_CERT="change_me"         # ./atlas.sh <target> compose generate-frp-certs <server>
export AUTHELIA_DB_PASSWORD="change_me"    # openssl rand -base64 32
export CROWDSEC_BOUNCER_KEY="change_me"    # openssl rand -hex 32
```

All secrets are generated with cryptographically secure random values or X.509 certificates rather than hardcoded defaults.

## HelmChart CR secret exposure

K3s `HelmChart` custom resources embed `valuesContent` directly in the CR spec, which is stored in the Kubernetes API (etcd/SQLite). This means any value passed to a Helm chart via `valuesContent` — including database passwords, encryption keys, JWKS private keys, and OIDC client secrets — is readable by anyone with `get` access to `helmcharts.helm.cattle.io` resources in the relevant namespace.

In a default K3s deployment, HelmChart CR access is restricted to cluster-admin and the `helm-controller` service account. For a single-user homelab, this exposure is acceptable but should be audited before granting namespace-level access to additional users or service accounts.

Affected charts: authelia (Redis password, DB password, encryption key, OIDC HMAC secret, JWKS key, OIDC client secrets), crowdsec (LAPI secret).

## Storage security

Most K3s persistent volumes use **Longhorn** (local block storage), which stores data directly on the host's filesystem at `$K3S_STATE_DIR` without network exposure. The cluster also retains an NFS server and CSI driver for workloads not yet migrated to Longhorn.

For remaining NFS workloads on multi-node deployments: use an isolated storage VLAN between nodes, deploy WireGuard tunnels between storage nodes, or use Flannel WireGuard backend (configured via `flannel-backend: wireguard-native` in K3s config) which encrypts all pod-to-pod traffic across nodes automatically — including NFS I/O.
