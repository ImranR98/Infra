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
- **Services:** Traefik reverse proxy, FRP server (frps), Authelia SSO, Plausible analytics, Docker socket proxy (via `wollomatic/socket-proxy`), Watchtower auto-updater, Shlink URL shortener, Uptime Kuma, metube, ISBN lookup, PixelNtfy, Syncthing relay server, logtfy, Owncast live streaming

### rpi — Raspberry Pi 400 webcam RTSP

A Raspberry Pi 400 (Ubuntu 24.04, arm64) running a single minimal Compose service (`go2rtc`) that turns a USB webcam into an authenticated RTSP stream.

- **Orchestrator:** Docker Compose
- **Services:** go2rtc (`alexxit/go2rtc:1.9.14`)
- **Stream:** `rtsp://admin:<password>@<pi>:8554/cam`
- **Video path:** single lazy FFmpeg source — reads the webcam as MJPEG and transcodes to H.264 using the Pi's hardware encoder (`bcm2835-codec-encode` /dev/video11 via `h264_v4l2m2m`, ~zero CPU). Falls back to software x264 if the `#hardware=v4l2m2m` param is dropped.
- **Device mapping:** webcam `/dev/video0` → container `/dev/video2`; H.264 encoder `/dev/video11` → container `/dev/video0` (ffmpeg's default m2m device path). The webcam's UVC metadata node (`/dev/video1`) is not mapped.
- **Auth:** username hardcoded to `admin`; password is auto-generated on first start, printed to `docker logs go2rtc`, and persisted at `current_target/compose_live_state/go2rtc/password` so it survives reboots. RTSP requires the password; the WebUI (`:1984`) is loopback-only and requires login.

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
