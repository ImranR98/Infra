# Luna

Docker-based self-hosted infrastructure running web services behind Traefik.

## Architecture

- **Traefik** — reverse proxy with automatic TLS via Let's Encrypt, country-based geoblocking, and a dashboard (localhost-only, accessible via SSH tunnel).
- **Authelia** — authentication and 2FA middleware protecting most services. Newly added services start behind Authelia and can be exposed directly after manual setup.
- **Watchtower** — automatic container image updates.
- **Docker socket proxy** — two instances isolate Docker socket access (read-only for Traefik, read-write for Watchtower).

Services include analytics (Plausible), file sharing (Send), media tools (MeTube), utilities (ISBN lookup, tracking pixels), and more.

## Files

```
compose.yaml                Service definitions (uses envsubst variables)
template.VARS.sh            Template for user configuration and secrets
luna.sh                     CLI entry point
prep_env.sh                 Helper library (sourced by luna.sh)
templates/
  authelia.config.yaml      Authelia configuration template
  traefik.dynamic-configuration.yaml  Traefik geoblock config
  plausible.ipv4-only.xml   ClickHouse IPv4-only config
  plausible.logs.xml        ClickHouse logging config
```

User-created file (gitignored):
```
VARS.sh
```

## Setup

### 1. Prerequisites

- Linux server (tested on Fedora Atomic/secureblue)
- A domain with DNS A/AAAA records pointing subdomains to your server
- Inbound access on **ports 80** (HTTP) and **443** (HTTPS) for web traffic
- Inbound access on **ports 22067/22070** (optional, only if using the Syncthing relay server)

Install prerequisites:
```
./luna.sh prereqs
```

### 2. Configure

```
cp template.VARS.sh VARS.sh
```

Edit `VARS.sh` with your values:
- `NODE_NAME`, `SERVICES_DOMAIN`, `DOMAIN_OWNER_EMAIL`
- Authelia encryption keys and secrets
- Plausible keys, PixelNtfy topic, etc.

### 3. DNS

List all required subdomains:
```
source prep_env.sh; findDomainsInSetup
```

Create DNS records for each.

### 4. Install

```
./luna.sh install
```

This creates the state directory structure, generates all config files, substitutes environment variables, and installs/starts the `luna` systemd service.

### 5. Post-install

Some services require manual initialization before they can be exposed publicly. When you re-run `./luna.sh install`, it asks whether to keep Authelia in front of these services. List them:

```
source prep_env.sh; envsubst < templates/authelia.config.yaml | grep -Eo 'domain:.+# IGNORE INITIALLY' | awk '{print $2}'
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `./luna.sh prereqs` | Install prerequisites |
| `./luna.sh install` | Install/update all services |
| `./luna.sh restart <service>` | Restart a single service |
| `./luna.sh backupState` | Back up state directory and VARS.sh |
| `./luna.sh old-images` | List Docker images older than 60 days |
| `./luna.sh update-socket-proxy` | Pull latest socket-proxy, restart Luna if updated |
| `./luna.sh update-traefik-plugins` | Update Traefik plugin versions |

## Maintenance

- All containers are managed by the `luna` systemd service: `systemctl [start|stop|restart|status] luna`
- Traefik dashboard: `ssh -L 8080:localhost:8080 user@your-server` then open `http://localhost:8080`
- State and data live in `$STATE_DIR` (default: `./state/`). This directory is auto-generated and should not be manually modified.
