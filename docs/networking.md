# Networking

Atlas manages networking at multiple layers: WireGuard VPN for secure connectivity, FRP (Fast Reverse Proxy) for NAT traversal, split-tunnel routing to protect Kubernetes subnets, and a preboot FRP tunnel for remote LUKS unlock.

## Network architecture

```
                          Internet
                             │
                             ▼
                           vps0
                 (Web VPS + FRP server)
                   Traefik :80/:443
                   Authelia, Plausible,
                   Watchtower, Uptime Kuma...
                   FRPS :7000 / :7500
                             │
                             │  FRP tunnel
                             │
                             ▼
                           srv0
                     (Home server)
           ┌───── K3s (Kubernetes) ─────┐
           │  Traefik Ingress :80/:443   │
           │  ~20 application workloads  │
           └─────────────────────────────┘
                FRPC sidecar (Compose)
                     │
                WireGuard VPN
                     │
              (split-tunnel)
```

## WireGuard

The `wireguard` command installs WireGuard tools and deploys a config file.

### Installation

```bash
./atlas.sh <target> wireguard <path-to-wireguard-conf>
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

### K3s startup ordering

A systemd drop-in ensures WireGuard starts *before* K3s:

```
# /etc/systemd/system/wg-quick@wg0.service.d/order-before-k3s.conf
[Unit]
Before=k3s.service
```

This guarantees the VPN is up before pods begin DNS resolution and network setup.

## FRP (Fast Reverse Proxy)

FRP provides NAT traversal for the home server. The flow:

1. **vps0** runs `frps` (FRP server) on a public VPS, listening on port 7000
2. **srv0** runs `frpc` (FRP client) as a Docker Compose sidecar, connecting to vps0
3. **vps0** forwards incoming traffic on ports 80, 443, and 8887 (SSH) through the tunnel to **srv0**

This lets srv0, which sits behind NAT, expose its services without a public IP.

### Authentication

FRP uses token-based authentication. The tokens (`FRPC_TOKEN`, `FRPC_PREBOOT_TOKEN`) are configured in both the FRPS server (vps0) and FRPC client (srv0). The custom `frps-with-multiuser` image supports multiple tokens for different authentication contexts.

### Health checks

Both frpc and frps have health checks hitting their respective admin API healthz endpoints. This allows Docker (and systemd) to detect and restart unhealthy tunnels.

## Preboot FRPC (LUKS unlock)

When the home server's root disk is LUKS-encrypted, the initramfs needs network access to receive the decryption passphrase via SSH. Atlas provides a target-specific command (`compose install-preboot`) that:

1. **Checks if root is LUKS-encrypted** via `check_root_luks.sh` (uses `lsblk -s` to detect crypt devices)
2. **Installs dracut-crypt-ssh** — embeds an SSH server in the initramfs that listens for connections
3. **Installs preboot FRPC** — embeds a minimal FRP client in the initramfs that tunnels SSH (port 8887) to the FRP server *before* the root filesystem is mounted

This allows the home server to boot unattended: the initramfs starts FRPC, tunnels SSH through the FRP server, and the operator can SSH in to provide the LUKS passphrase remotely.

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
- `get_node_lan_subnet()` — returns the CIDR subnet of the primary interface (used for LAN whitelist middleware)
