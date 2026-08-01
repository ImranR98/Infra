# Targets

A **target** is a named machine that Infra manages. Each target lives in its own directory under `targets/`. Targets are the unit of operation — every `infra.sh` invocation specifies a target as its first argument.

## What defines a target

Every target directory contains:

- `VARS.template.sh` — a file listing all environment variables the target needs, with placeholder values and generation instructions
- Either a `compose/` directory (Docker Compose stack), a `k3s/` directory (Kubernetes workloads), or both
- Optionally a `commands/` directory with target-specific command overrides

The actual secrets live outside the target directory, in `secrets/VARS.<target>.sh`. These files are gitignored (root `VARS.<target>.sh` is also supported as fallback).

## Current targets

This documentation is generated at a point in time. Targets may be added, removed, or reconfigured. Check `targets/` for the authoritative list.

### srv0 — Primary home server

The main homelab server. Runs a full K3s cluster with ~20 application workloads, plus a small Docker Compose sidecar for FRPC tunneling.

- **Orchestrator:** K3s (control-plane node) + Docker Compose sidecar
- **K3s workloads (base):** Namespaces, NFS server, NFS CSI driver, cert-manager, Traefik ingress, CrowdSec, Authelia SSO, ntfy notifications
- **K3s workloads (apps):** Immich, Jellyfin, Navidrome, Home Assistant, Nextcloud, Ollama + Open WebUI, FreshRSS, mosquitto, Syncthing, mdScl, OPodSync, D$CPLN, OpenCanary, FMD, logtfy
- **Compose:** FRPC sidecar (tunnels K3s services through the FRP server)
- **Special:** LUKS-aware preboot FRPC for remote SSH unlock of encrypted root filesystem

### vps0 — Web-services VPS + FRP server

A VPS running a Docker Compose stack of public-facing web services and the FRP server that provides NAT traversal for srv0.

- **Orchestrator:** Docker Compose
- **Services:** Traefik reverse proxy, FRP server (frps), Authelia SSO, Plausible analytics, Docker socket proxy (via `wollomatic/socket-proxy`), Watchtower auto-updater, Shlink URL shortener, Uptime Kuma, metube, ISBN lookup, PixelNtfy, Syncthing relay server, logtfy

### pc0 — Desktop PC (streaming)

A desktop PC running a Docker Compose stack for Owncast live streaming with FRP tunneling.

- **Orchestrator:** Docker Compose
- **Services:** Traefik reverse proxy, FRPC sidecar (tunnels through vps1), Owncast streaming server, Docker socket proxy

### vps1 — Secondary edge VPS + FRP server

A VPS running a Docker Compose stack with an FRP server dedicated to the pc0 tunnel.

- **Orchestrator:** Docker Compose
- **Services:** Traefik reverse proxy, FRP server (frps), hello (placeholder service)

## Target configuration patterns

### Variable templates

Each `VARS.template.sh` documents exactly what variables a target needs. Variables cover:
- Domain names and email addresses
- Passwords, tokens, and encryption keys (with generation commands in comments)
- Host filesystem paths
- Multi-line configuration blocks (maintaining YAML indentation)

### Compose targets

Targets that use Docker Compose have:
- `compose/compose.yaml` — the Compose file with `$VARIABLE` placeholders
- `compose/templates/` — service config files (rendered into `current_target/compose_live_state/`)

### K3s targets

Targets that use Kubernetes have:
- `k3s/groups.yaml` — deployment groups specifying order of operations
- `k3s/<component>/` — one directory per deployable unit

### Target-specific commands

Any target can override a global command by placing a script at `targets/<name>/commands/<path>/<cmd>.sh`. The dispatch system checks here first. For example, `srv0` overrides `compose install-preboot` with LUKS-aware logic that doesn't apply to other targets.

## Adding a new target

1. Create `targets/<name>/` with `VARS.template.sh`
2. Add `compose/compose.yaml` and/or `k3s/` directory as needed
3. Create `secrets/VARS.<name>.sh` following the template
4. Any target-specific commands go in `targets/<name>/commands/`
5. The target is immediately usable: `./infra.sh <name> <command>`
