# Infra

Infra is a single-repo, shell-driven infrastructure-as-code system for managing a homelab of Linux servers. It deploys and orchestrates Docker Compose stacks and K3s (lightweight Kubernetes) workloads across multiple machines — private servers, VPS instances, and remote agents — all from one CLI.

*The docs assume familiarity with Docker Compose, K3s/kubectl/kustomize, and Traefik. They focus on how Infra wires these tools together and what's unique to this repo.*

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

## What it does

- **One CLI for everything.** `./infra.sh <target> <command>` is the entry point. Targets are named machines; commands do the work.
- **Docker Compose management.** Render templates, spin up Compose stacks as systemd services, back up runtime state, swap individual services.
- **K3s cluster management.** Bootstrap control-plane nodes, join remote agent nodes via SSH, deploy Kubernetes workloads through `kubectl kustomize` with a full component lifecycle (apply, delete, diff, render).
- **Declarative configuration.** All infrastructure is defined as YAML/TOML/JSON templates with `$VARIABLE` placeholders. Per-target environment files provide secrets at runtime.
- **Automated updates.** Renovate scans all Docker images, Helm charts, and Traefik plugins across the repo and applies version bumps to source files automatically.
- **Networking built in.** WireGuard VPN with split-tunnel routing, FRP reverse proxy tunneling for NAT traversal, and preboot FRPC for LUKS-encrypted root SSH unlock.
- **Security-focused.** Secrets live in `.secret` files with restricted permissions, LUKS-aware initramfs hooks, Authelia SSO with 2FA, CrowdSec intrusion prevention, and geoblock middleware.

## Quick start

```bash
# Install prerequisites (Docker, yq, envsubst, jq, python3)
./infra.sh <target> prereqs

# Create your variables file from the template
cp targets/<target>/VARS.template.sh VARS.<target>.sh
# Edit VARS.<target>.sh with your secrets and settings

# Validate your configuration
./infra.sh <target> validate

# Deploy
./infra.sh <target> compose install
./infra.sh <target> k3s group base apply
./infra.sh <target> k3s group apps apply
```

## Documentation

All documentation lives in [AGENTS.md](AGENTS.md): architecture, targets, commands, templating, Compose/K3s conventions, networking, security, and the Renovate update workflow. See the [architecture diagram](architecture.svg).

## Requirements

- Linux (apt, dnf, or rpm-ostree-based distro)
- Bash 4+
- Docker + Docker Compose v2
- kubectl (for K3s targets)
- yq, envsubst, jq, curl, python3
