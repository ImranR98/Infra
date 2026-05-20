# Atlas

Self-hosted infrastructure with 3 deployment targets: **luna**, **lens**, and **sol**.

```
 lens (small VPS)      sol (powerful home server)         luna (medium VPS)
 ┌──────────────┐     ┌──────────────────────────┐       ┌────────────────────────┐
 │   frps       │◀───│ K3s cluster (services)   │       │  Docker Compose stack  │ 
 │   logtfy     │     │ frpc (tunnels to lens)   │       │  (Traefik, Authelia,   │
 └──────────────┘     │ preboot FRPC (initramfs) │       │  Plausible, Send, ...) │
                      └──────────────────────────┘       └────────────────────────┘
```

## Targets

| Target | Role | Stack |
|--------|------|-------|
| **luna** | Cloud VPS — standalone | Docker Compose (Traefik, Authelia, Plausible, Send, MeTube, PixelNtfy, ISBN lookup, logtfy, Syncthing relay, dockerproxy, watchtower) |
| **lens** | Relay VPS — FRP tunnel endpoint | Docker Compose (FRP server, logtfy) |
| **sol** | Home server — K3s cluster + FRPC | K3s (Kustomize) for services + Docker Compose for FRPC |

Luna is a low-powered cloud VPS running its own compose stack behind Traefik with Authelia 2FA — it is independent of the Sol/Lens system. Sol is the high-powered home server where most services run (K3s cluster), exposed to the internet via an FRPC tunnel back to Lens.

## Files

```
atlas.sh                    CLI entry point (takes <target> <command>)
VARS.sh                     User configuration (gitignored, copy from vars/)
compose/
  luna.compose.yaml         Compose services for luna
  lens.compose.yaml         Compose services for lens
  sol.compose.yaml          Compose services for sol (FRPC only)
lib/                        Shared libraries
  vars.sh                   VARS sourcing and validation (used by atlas.sh and K3s scripts)
k3s/sol/                    K3s manifests for sol
  Makefile                  Make targets: k3s, base, apps, all, validate, domains
  scripts/
    apply.sh                Kustomize → envsubst → kubectl pipeline
    validate.sh             Kustomization + env var validation
    update-versions.py      Helm chart + image version pinning
  components/
    k3s/                    K3s cluster installation (k3s.sh, firewall.sh)
    namespaces/             Namespaces + default-deny network policies
    nfs-server/             NFS server for shared media
    csi-driver-nfs/         NFS CSI driver
    longhorn/               Distributed block storage
    cert-manager/           TLS certificates
    traefik/                Ingress controller
    crowdsec/               WAF / IP banning
    authelia/               SSO / OIDC provider
    ntfy/                   Notification backbone
    .../                 several other services
vars/
  VARS.common.sh            Shared variables
  VARS.luna.sh              luna configuration template
  VARS.lens.sh              lens configuration template
  VARS.sol.sh               sol configuration template
templates/
  luna/                     Config file templates for luna
  lens/                     Config file templates for lens
  sol/                      Config file templates for sol (FRPC only)
scripts/
  check_root_luks.sh        Check if root partition is LUKS-encrypted
  dracut-crypt-ssh.install.sh  Install dracut-crypt-ssh for remote LUKS unlock
  frpc-preboot.install.sh   Install preboot FRPC in initramfs
state/                      Runtime state (auto-generated, gitignored)
```

## Prerequisites

- A Linux server with `systemd` and one of: `apt`, `dnf`, or `rpm-ostree`
- Required ports depend on the target (see the VARS template)

Install system prerequisites (Docker, yq, envsubst, jq, curl, python3, python3-yaml):
```
./atlas.sh prereqs
```

For Sol, you also need a K3s cluster (installed via the `k3s` Make target).

## Setup

### 1. Configure

Pick a target and copy its VARS template:
```
cp vars/VARS.luna.sh VARS.sh
```

Edit `VARS.sh` with your values (each template documents its required variables).

### 2. DNS

List all required subdomains for your target:
```
./atlas.sh luna list-domains
```

For Sol's K3s services:
```
./atlas.sh sol k3s domains
```

Create DNS records for each.

### 3. Install

**Luna / Lens** (Docker Compose):
```
./atlas.sh luna install
./atlas.sh lens install
```

**Sol** (K3s + FRPC):
```
# Step 1: Install FRPC (Docker Compose) to tunnel back to Lens
./atlas.sh sol install

# Step 2: Install/repair K3s cluster (idempotent, skips if kubectl works)
./atlas.sh sol k3s k3s

# Step 3: Deploy K3s base infrastructure (namespaces, storage, ingress, SSO, etc.)
./atlas.sh sol k3s base

# Step 4: Deploy K3s application workloads
./atlas.sh sol k3s apps
```

### 4. Post-install

**Luna only**: The first `install` run comments out `# IGNORE INITIALLY` lines in Authelia's config, keeping new services protected. Re-run `install` after initial setup to expose them.

**Sol only**: Some components have `post.sh` hooks (cert-manager applies issuers, ntfy provisions users). These run automatically on first deploy. The initial deploy mode (`APPLY_MODE=initial`) comments out `# IGNORE INITIALLY` lines from Authelia and Jellyfin configs.

## Configuration

VARS templates are at `vars/VARS.<target>.sh` with a shared base at `vars/VARS.common.sh`. Copy the target's template to `VARS.sh` and fill in the values. Each template documents its required variables.

## CLI Commands

```
Usage: ./atlas.sh <target> <command>

Targets:
  luna
  lens
  sol

Commands:
  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl)
  install                   Install and start all compose services
  install-preboot           Install preboot FRPC in initramfs (for remote LUKS unlock)
  k3s [target]              Run K3s Make target (passes through to k3s/<target>/Makefile)
  restart <service>         Restart a single compose service
  list-domains              List all required subdomains for compose services
  backup-state              Back up state directory and VARS.sh
  old-images                List Docker images older than 60 days
  update-socket-proxy       Pull latest socket-proxy and restart if needed
  update-traefik-plugins    Update Traefik plugin versions
```

### K3s Make targets (for sol)

```
./atlas.sh sol k3s             # Show help
./atlas.sh sol k3s k3s         # Install/repair K3s cluster (idempotent)
./atlas.sh sol k3s base        # Deploy base K8s infrastructure
./atlas.sh sol k3s apps        # Deploy application workloads
./atlas.sh sol k3s all         # k3s + base + apps
./atlas.sh sol k3s validate    # Validate Kustomize structure and env vars
./atlas.sh sol k3s domains     # List domains required by IngressRoutes
./atlas.sh sol k3s <component> # Deploy a specific component
```

Additional Make variables:
- `APPLY_MODE=delete` — Delete a component and its PVCs
- `APPLY_MODE=diff` — Preview changes with `kubectl diff`
- `APPLY_MODE=initial` — Comment out `# IGNORE INITIALLY` lines on first deploy
- `APPLY_MODE=yaml` — Print processed YAML without applying

## Maintenance

- Compose containers are managed by a systemd service per target: `systemctl [start|stop|restart|status] <target>`
- K3s components are managed via `kubectl` through the Makefile targets
- State and data live in `state/` (relative to the repo root). Auto-generated, do not modify manually.
- Back up state and secrets with `./atlas.sh <target> backup-state`
- Update Helm chart versions and container image tags with: `./atlas.sh sol k3s update`
