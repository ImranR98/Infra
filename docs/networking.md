# Networking

Infra manages networking at multiple layers: WireGuard VPN for secure connectivity, FRP (Fast Reverse Proxy) for NAT traversal, split-tunnel routing to protect Kubernetes subnets, and a preboot FRP tunnel for remote LUKS unlock.

## Network architecture

```
                           Internet
                              │
                         ┌────┴────┐
                         │ :80     │ :443
                         ▼         ▼
                    ┌────── vps0 ──────┐
                    │   Traefik        │
                    │   routes by      │
                    │   Host / SNI     │
                    │   │        │     │
                    │   ▼        ▼     │
                    │ local    FRPS    │
                    │ apps   :8080     │
                    │        :8443     │
                    │   ports :7000    │
                    │         :8887    │
                    └─────────│────────┘
                              │ FRP tunnel
                    ┌─────────┴────────┐
                    │                  │
                    │       srv0       │
                    │ Traefik :80:443  │
                    │ cert-manager TLS │
                    │ K3s apps         │
                    │ FRPC sidecar     │
                    └──────────────────┘
                         │
                    WireGuard VPN
                         │
                   (split-tunnel)
```

## WireGuard

The `wireguard` command installs WireGuard tools and deploys a config file.

### Installation

```bash
./infra.sh <target> wireguard <path-to-wireguard-conf>
```

This:
1. Installs `wireguard-tools` via the detected package manager
2. Copies the provided config to `/etc/wireguard/wg0.conf` with `chmod 600`
3. Enables and starts the `wg-quick@wg0` systemd service

### Split-tunnel routing

WireGuard's `AllowedIPs` is rewritten to `0.0.0.0/1, 128.0.0.0/1` instead of the typical `0.0.0.0/0`. This is a routing trick:

- `0.0.0.0/1` and `128.0.0.0/1` together cover all IPv4 addresses
- But these routes are *less specific* than directly-connected LAN routes (e.g., `/24`)
- This means K3s pod and service subnets (`10.42.0.0/16`, `10.43.0.0/16`) stay on the physical NIC
- The LAN subnet also stays local

Result: VPN traffic routes through WireGuard, but Kubernetes and LAN traffic stay direct.

### Endpoint dead-loop fix

Since the VPN endpoint falls inside `0.0.0.0/1`, a `PostUp` rule is added to ensure the endpoint always uses the physical gateway:

```
PostUp = ip route add <endpoint>/32 via <gateway>
PreDown = ip route delete <endpoint>/32 via <gateway>
```

Without this, WireGuard's own handshake packets would be routed into the tunnel instead of out the physical interface.

### Systemd restart resilience

WireGuard is configured with automatic restart via a systemd drop-in (`restart.conf`) that sets `Restart=on-failure` and `RestartSec=15`. This ensures the VPN recovers from transient failures without manual intervention.

## FRP (Fast Reverse Proxy)

FRP provides NAT traversal for the home server. **vps0** runs `frps` (FRP server) on a public VPS using the official `fatedier/frps` Docker image. **srv0** runs `frpc` (FRP client) as a Docker Compose sidecar, connecting to vps0 on port 7000. The tunnel carries HTTP, HTTPS, and SSH traffic from vps0 to srv0, letting a machine behind NAT expose services without a public IP.

### Traffic routing

vps0 runs a single Traefik instance that receives all public HTTP and HTTPS traffic on ports 80 and 443. Traefik inspects the `Host` header (HTTP) or SNI (HTTPS) and splits traffic by domain:

**vps0-local services** — served directly by containers running on vps0. vps0 splits its domains into two zones:

**`$BASE_SERVICES_DOMAIN`** (the original domain) — public apps, no Authelia:

- `plausible.$BASE_SERVICES_DOMAIN` — Plausible analytics (public; the tracking script is loaded by other pages)
- `ln.$BASE_SERVICES_DOMAIN` — Shlink URL shortener API (public — short links must redirect for anyone; the web UI lives at `ui.ln.$CLOUD_SERVICES_DOMAIN`)
- `ikom.$BASE_SERVICES_DOMAIN` — Ikomm old URL (301 → `ikom.$CLOUD_SERVICES_DOMAIN`)
- `apps.obtainium.$BASE_SERVICES_DOMAIN` — Obtainium app update checker
- `sb25.$BASE_SERVICES_DOMAIN` — SB25 (self-hosted service)

**`$CLOUD_SERVICES_DOMAIN`** (e.g. `cloud.$BASE_SERVICES_DOMAIN`) — the remaining services (public, no Authelia unless noted):

- `auth.$CLOUD_SERVICES_DOMAIN` — Authelia SSO admin (Authelia-protected)
- `traefik.$CLOUD_SERVICES_DOMAIN` — Traefik dashboard (Authelia-protected)
- `ytdl.$CLOUD_SERVICES_DOMAIN` — metube (Authelia-protected)
- `ikom.$CLOUD_SERVICES_DOMAIN` — Ikomm (Authelia-protected)
- `ui.ln.$CLOUD_SERVICES_DOMAIN` — Shlink web client (Authelia-protected)
- `uptime.$CLOUD_SERVICES_DOMAIN` — Uptime Kuma monitoring (Authelia-protected)
- `isbn.$CLOUD_SERVICES_DOMAIN` — ISBN book barcode lookup (public)
- `pixelntfy.$CLOUD_SERVICES_DOMAIN` — PixelNtfy push notifications (public — tracking pixels load on third-party sites)
- `owncast.$CLOUD_SERVICES_DOMAIN` — Owncast live streaming (web UI + RTMP ingest on `:1935`; own token auth, not Authelia)
- `cct26.$CLOUD_SERVICES_DOMAIN` — CCT26 (Reddit + LLM tool; resolves to the same URL as before — `example.org.$BASE_SERVICES_DOMAIN`)

These are configured via Docker container labels on the Traefik provider. Each `Host(...)` label tells Traefik to load-balance to the matching Docker container on the internal `traefik` network.

**srv0-proxied services** — requests for `home.$BASE_SERVICES_DOMAIN` and `*.home.$BASE_SERVICES_DOMAIN` are forwarded through the FRP tunnel to srv0's K3s Traefik ingress. This routing is defined in Traefik's file provider (`dynamic-configuration.yaml`) rather than Docker labels, because the destination (FRPS) is the intermediary, not a direct container:

- **HTTP** (`:80`): Traefik routes `Host(home.$BASE_SERVICES_DOMAIN) || Host(*.home.$BASE_SERVICES_DOMAIN)` on the `web` entrypoint to `http://frps:8080`. FRPS receives the plain HTTP request and proxies it through the FRP tunnel to srv0's K3s Traefik ingress.
- **HTTPS** (`:443`): Traefik routes `HostSNI(home.$BASE_SERVICES_DOMAIN) || HostSNI(*.home.$BASE_SERVICES_DOMAIN)` on the `websecure` entrypoint to `frps:8443` with `tls.passthrough: true`. vps0's Traefik does **not** terminate TLS — it forwards the raw encrypted TCP stream with Proxy Protocol v2. TLS termination, certificate issuance, and renewal are handled entirely by cert-manager on srv0's K3s cluster.

TLS passthrough is used for srv0 traffic so that both targets don't need to coordinate certificates. If vps0 terminated TLS, it would need to hold and renew srv0's certificates, creating a coupling between independent targets. Instead, vps0 treats the TLS stream as opaque bytes and srv0's cert-manager maintains its own Let's Encrypt lifecycle independently.

**Non-HTTP ports** — FRPS binds several ports directly on the vps0 host (bypassing Traefik entirely):

| Port | Purpose |
|------|---------|
| 7000 | FRP control channel — frpc on srv0 connects here to establish and maintain the tunnel |
| 8887 | Preboot SSH — forwarded through the tunnel to srv0's initramfs SSH server for remote LUKS passphrase entry |
| 8888 | Additional tunnel port (e.g., TCP service forwarding) |

### Authentication

FRP uses mutual TLS (mTLS) for authentication. A per-pair CA issues client and server certificates. The server (`frps`) verifies the client's certificate against the CA and the client verifies the server's certificate likewise. Preboot and post-boot FRPC on srv0 use different client certificates for credential isolation.

### Certificate generation

Use `./infra.sh <client-target> compose generate-mtls-certs <server-target>` to generate certificates for a client↔server pair. The command outputs copy-paste blocks for the VARS files of both targets. See `commands/compose/generate-mtls-certs.sh`.

### Health checks

frps has a health check hitting its admin API healthz endpoint (`:7500`). frpc uses a process-level health check (`pgrep frpc`). This allows Docker's health check system to detect and restart unhealthy tunnels; Docker's `restart: always` policy recovers from crashes and reboot.

## Preboot FRPC (LUKS unlock)

When the home server's root disk is LUKS-encrypted, the initramfs needs network access to receive the decryption passphrase via SSH. Infra provides a target-specific command (`compose install-preboot`) that:

1. **Checks if root is LUKS-encrypted** via `check_root_luks.sh` (uses `lsblk -s` to detect crypt devices)
2. **Installs dracut-crypt-ssh** — embeds an SSH server in the initramfs that listens for connections
3. **Installs preboot FRPC** — embeds a minimal FRP client in the initramfs that tunnels SSH (port 8887) to the FRP server *before* the root filesystem is mounted

This allows the home server to boot unattended: the initramfs starts FRPC, tunnels SSH through the FRP server, and the operator can SSH in to provide the LUKS passphrase remotely.

`bigpc` skips the FRPC step: its `install-preboot` variant installs only crypt-ssh with the dropbear port patched to 8887, so the initramfs SSH is reachable directly over the LAN (ethernet required — the wifi-net module is not installed).

### How it works

```
Boot → initramfs loads → preboot FRPC starts
  → FRPC connects to vps0:7000 (FRPS)
  → vps0 exposes port 8887 → forwarded to srv0's SSH in initramfs
  → Operator SSHs to vps0:8887 → reaches srv0's initramfs SSH
  → Provides LUKS passphrase → root unlocks → boot continues
```

## Domain extraction

The built-in `list-domains` command extracts all `Host(...)` domains from IngressRoutes (K3s) and Compose rules to show what domains the target exposes. This is helpful for DNS configuration and Let's Encrypt planning.

## Network utility functions

`lib/common.sh` provides networking utilities used throughout the codebase:

- `get_node_ip()` — detects the primary IPv4 address by looking at the default route interface
