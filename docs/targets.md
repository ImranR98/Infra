# Targets

A **target** is a named machine that Atlas manages. Each target lives in its own directory under `targets/`. Targets are the unit of operation — every `atlas.sh` invocation specifies a target as its first argument.

## What defines a target

Every target directory contains:

- `VARS.template.sh` — a file listing all environment variables the target needs, with placeholder values and generation instructions
- Either a `compose/` directory (Docker Compose stack), a `k3s/` directory (Kubernetes workloads), or both
- Optionally a `commands/` directory with target-specific command overrides

The actual secrets live outside the target directory, at the repo root, as `VARS.<target>.sh`. These files are gitignored.

## Current targets

This documentation is generated at a point in time. Targets may be added, removed, or reconfigured. Check `targets/` for the authoritative list.

### sol — Primary home server

The main homelab server. Runs a full K3s cluster with ~20 application workloads, plus a small Docker Compose sidecar for FRPC tunneling.

- **Orchestrator:** K3s (control-plane node) + Docker Compose sidecar
- **K3s workloads (base):** Namespaces, NFS server, NFS CSI driver, Longhorn storage, cert-manager, Traefik ingress, CrowdSec, Authelia SSO, ntfy notifications
- **K3s workloads (apps):** Immich, Jellyfin, Navidrome, Home Assistant, Nextcloud, Ollama + Open WebUI, FreshRSS, mosquitto, Syncthing, mdScl, OPodSync, D$CPLN, OpenCanary, FMD, logtfy
- **Compose:** FRPC sidecar (tunnels K3s services through the FRP server)
- **Special:** LUKS-aware preboot FRPC for remote SSH unlock of encrypted root filesystem

### luna — Web-services VPS

A VPS running a Docker Compose stack of public-facing web services.

- **Orchestrator:** Docker Compose
- **Services:** Traefik reverse proxy, Authelia SSO, Plausible analytics, socket-proxy (Docker socket security), Watchtower auto-updater, Shlink URL shortener, Uptime Kuma, metube, ISBN lookup, PixelNtfy, Syncthing relay server, logtfy

### lens — FRP server VPS

A VPS dedicated to running the FRP server (frps) that acts as the public entry point for sol's tunnels.

- **Orchestrator:** Docker Compose
- **Services:** frps-with-multiuser (custom FRP server with per-user token auth), logtfy

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

Any target can override a global command by placing a script at `targets/<name>/commands/<path>/<cmd>.sh`. The dispatch system checks here first. For example, `sol` overrides `compose install-preboot` with LUKS-aware logic that doesn't apply to other targets.

## Adding a new target

1. Create `targets/<name>/` with `VARS.template.sh`
2. Add `compose/compose.yaml` and/or `k3s/` directory as needed
3. Create `VARS.<name>.sh` at the repo root following the template
4. Any target-specific commands go in `targets/<name>/commands/`
5. The target is immediately usable: `./atlas.sh <name> <command>`
