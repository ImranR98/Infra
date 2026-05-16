# Luna

Docker-based self-hosted infrastructure running web services behind Traefik.

Supports 3 deployment targets: **luna**, **lens**, and **sol**.

## Architecture

- **Traefik** — reverse proxy with automatic TLS via Let's Encrypt, country-based geoblocking, and a dashboard (localhost-only, accessible via SSH tunnel).
- **Authelia** — authentication and 2FA middleware applied at the Traefik entrypoint level. All HTTPS traffic is verified by Authelia; services are exposed by adding bypass rules in Authelia's access control config.
- **Watchtower** — automatic container image updates.
- **Docker socket proxy** — two instances isolate Docker socket access with different permission levels (read-only for Traefik, read-write for Watchtower).

Services include analytics (Plausible), file sharing (Send), media tools (MeTube), utilities (ISBN lookup, tracking pixels), and more.

## Files

```
compose.sh                  CLI entry point (takes [<target>] <command>)
compose/
  luna.compose.yaml         Service definitions for luna
  lens.compose.yaml         Service definitions for lens
  sol.compose.yaml          Service definitions for sol
vars/
  VARS.luna.sh              Template for luna user configuration
  VARS.lens.sh              Template for lens user configuration
  VARS.sol.sh               Template for sol user configuration
templates/
  luna/                     Template config files for luna services
  lens/                     Template config files for lens services
  sol/                      Template config files for sol services
```

User-created file (gitignored):
```
VARS.sh
```

## Setup

### 1. Prerequisites

- Ubuntu server (or anything with `sudo`, `apt`, and `systemd`)
- A domain with DNS A/AAAA records pointing subdomains to your server
- Inbound access on **ports 80** (HTTP) and **443** (HTTPS) for web traffic, and **ports 22067/22070** for the Syncthing relay server

Install prerequisites:
```
./compose.sh prereqs
```

### 2. Configure

Pick a target and copy its VARS template:
```
cp vars/VARS.luna.sh VARS.sh
```

Edit `VARS.sh` with your values:
- `SERVICES_DOMAIN`, `DOMAIN_OWNER_EMAIL`
- Authelia encryption keys and secrets
- Plausible keys, PixelNtfy topic, etc.

### 3. DNS

List all required subdomains for your target:
```
./compose.sh luna list-domains
```

Create DNS records for each.

### 4. Install

```
./compose.sh luna install
```

This creates the state directory structure, generates all config files, substitutes environment variables, and installs/starts the `luna` systemd service.

To target a different deployment, replace `luna` with `lens` or `sol`.

### 5. Post-install

By default, all services are behind Authelia authentication. The first time you run `install`, lines ending with `# IGNORE INITIALLY` in the Authelia config are commented out — this keeps new services protected until you've done initial setup. After doing so, re-run `install` to expose it without authentication.

## CLI Commands

```
Usage: ./compose.sh [<target>] <command>

Targets:
  luna                      (default)
  lens
  sol

Commands:
  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl)
  install                   Install and start all services
  restart <service>         Restart a single service
  list-domains              List all required subdomains
  backup-state              Back up state directory and VARS.sh
  old-images                List Docker images older than 60 days
  update-socket-proxy       Pull latest socket-proxy and restart if needed
  update-traefik-plugins    Update Traefik plugin versions
```

## Maintenance

- All containers are managed by a systemd service per target: `systemctl [start|stop|restart|status] luna`
- Traefik dashboard: `ssh -L 8080:localhost:8080 user@your-server` then open `http://localhost:8080`
- State and data live in `$STATE_DIR` (default: `./state/`). This directory is auto-generated and should not be manually modified.
- Back up state and secrets with `./compose.sh backup-state`
