# Luna

Docker-based self-hosted infrastructure running web services behind Traefik.

## Architecture

- **Traefik** — reverse proxy with automatic TLS via Let's Encrypt, country-based geoblocking, and a dashboard (localhost-only, accessible via SSH tunnel).
- **Authelia** — authentication and 2FA middleware applied at the Traefik entrypoint level. All HTTPS traffic is verified by Authelia; services are exposed by adding bypass rules in Authelia's access control config.
- **Watchtower** — automatic container image updates.
- **Docker socket proxy** — two instances isolate Docker socket access with different permission levels (read-only for Traefik, read-write for Watchtower).

Services include analytics (Plausible), file sharing (Send), media tools (MeTube), utilities (ISBN lookup, tracking pixels), and more.

## Files

```
compose.yaml                Service definitions (uses envsubst variables)
template.VARS.sh            Template for user configuration and secrets
luna.sh                     CLI entry point
templates/
  authelia.config.yaml      Authelia configuration template
  traefik.dynamic-configuration.yaml  Traefik dynamic config (middlewares)
  plausible.clickhouse-config.xml  ClickHouse config
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
./luna.sh prereqs
```

### 2. Configure

```
cp template.VARS.sh VARS.sh
```

Edit `VARS.sh` with your values:
- `SERVICES_DOMAIN`, `DOMAIN_OWNER_EMAIL`
- Authelia encryption keys and secrets
- Plausible keys, PixelNtfy topic, etc.

### 3. DNS

List all required subdomains:
```
./luna.sh list-domains
```

Create DNS records for each.

### 4. Install

```
./luna.sh install
```

This creates the state directory structure, generates all config files, substitutes environment variables, and installs/starts the `luna` systemd service.

### 5. Post-install

By default, all services are behind Authelia authentication. The first time you run `install`, lines ending with `# IGNORE INITIALLY` in the Authelia config are commented out — this keeps new services protected until you've done initial setup. After doing so, re-run `install` to expose it without authentication.

## CLI Commands

Run `./luna.sh` to see all CLI commands.

## Maintenance

- All containers are managed by the `luna` systemd service: `systemctl [start\|stop\|restart\|status] luna`
- Traefik dashboard: `ssh -L 8080:localhost:8080 user@your-server` then open `http://localhost:8080`
- State and data live in `$STATE_DIR` (default: `./state/`). This directory is auto-generated and should not be manually modified.
- Back up state and secrets with `./luna.sh backup-state`
