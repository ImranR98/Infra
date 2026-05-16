# Atlas

Self-hosted infrastructure with 3 deployment targets: **luna**, **lens**, and **sol**.

```
  lens (small VPS)    sol (powerful home server)             luna (medium VPS)
 ┌────────────┐      ┌───────────────────────────────┐      ┌──────────────────────┐
 │   frps     │      │   several services (in K3s)   │      │   several services   │
 │   logtfy   │────▶│   frpc                        │      └──────────────────────┘
 └────────────┘      └───────────────────────────────┘      
               
```

## Targets

| Target | Role | Services |
|--------|------|------------------------|
| **luna** | Cloud VPS — standalone compose stack | Traefik, Authelia, Plausible, Send, MeTube, PixelNtfy, ISBN lookup, logtfy, Syncthing relay, dockerproxy, watchtower |
| **lens** | Relay server — FRP tunnel endpoint for Sol | FRP server (multi-user), logtfy |
| **sol** | Home server — FRPC client tunnels back to Lens (services run on K3s, not Docker Compose) | FRP client |

Luna is a low-powered cloud VPS running its own compose stack behind Traefik with Authelia 2FA — it is independent from the Sol/Lens system. Sol is the high-powered home server where most services run (in a K3s cluster); it is exposed to the internet via an FRPC tunnel back to Lens.

## Files

```
atlas.sh                    CLI entry point (takes <target> <command>)
compose/
  luna.compose.yaml         Service definitions for luna
  lens.compose.yaml         Service definitions for lens
  sol.compose.yaml          Service definitions for sol
vars/
  VARS.common.sh            Shared variables across all targets
  VARS.luna.sh              Template for luna user configuration
  VARS.lens.sh              Template for lens user configuration
  VARS.sol.sh               Template for sol user configuration
templates/
  luna/                     Template config files for luna services
  lens/                     Template config files for lens services
  sol/                      Template config files for sol services
scripts/
  check_root_luks.sh        Check if root partition is LUKS-encrypted
  dracut-crypt-ssh.install.sh  Install dracut-crypt-ssh for remote LUKS unlock
  frpc-preboot.install.sh   Install preboot FRPC in initramfs
state/                      Runtime state (auto-generated, gitignored)
```

User-created file (gitignored):
```
VARS.sh
```

## Prerequisites

- A Linux server with `systemd` and one of: `apt`, `dnf`, or `rpm-ostree`
- Required ports depend on the target (see the VARS template for your target)

Install prerequisites (Docker, yq, envsubst, jq, curl):
```
./atlas.sh prereqs
```

## Setup

### 1. Configure

Pick a target and copy its VARS template:
```
cp vars/VARS.luna.sh VARS.sh
```

Edit `VARS.sh` with your values (each VARS template documents its required variables).

### 2. DNS

List all required subdomains for your target:
```
./atlas.sh luna list-domains
```

Create DNS records for each.

### 3. Install

```
./atlas.sh luna install
```

This creates the state directory structure, generates all config files, substitutes environment variables, and installs/starts the target's systemd service.

To target a different deployment, replace `luna` with `lens` or `sol`.

### 4. Post-install (luna only)

By default, all services are behind Authelia authentication. The first time you run `install` on luna, lines ending with `# IGNORE INITIALLY` in the Authelia config are commented out — this keeps new services protected until you've done initial setup. After doing so, re-run `install` to expose them without authentication.

## Configuration

VARS templates are at `vars/VARS.<target>.sh` with a shared base at `vars/VARS.common.sh`. Copy the target's template to `VARS.sh` and fill in the values — each template documents its required variables.

## CLI Commands

```
Usage: ./atlas.sh <target> <command>

Targets:
  luna
  lens
  sol

Commands:
  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl)
  install                   Install and start all services
  install-preboot           Install preboot FRPC in initramfs (for remote LUKS unlock)
  restart <service>         Restart a single service
  list-domains              List all required subdomains
  backup-state              Back up state directory and VARS.sh
  old-images                List Docker images older than 60 days
  update-socket-proxy       Pull latest socket-proxy and restart if needed
  update-traefik-plugins    Update Traefik plugin versions
```

## Maintenance

- All containers are managed by a systemd service per target: `systemctl [start|stop|restart|status] <target>`
- State and data live in `state/` (relative to the repo root). This directory is auto-generated and should not be manually modified.
- Back up state and secrets with `./atlas.sh <target> backup-state`
