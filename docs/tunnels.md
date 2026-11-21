# Tunnels and remote access

Two WireGuard-based paths: a public-exposure tunnel that carries the public `home.*`
tree to `srv0`, and an AmneziaWG remote-access VPN for full-tunnel clients.

## Public-exposure tunnel

```text
vps0 hub pubexp-server0 (10.99.0.1)
  ├── srv0 host pubexp-client0 (10.99.0.2)
  ├── qBittorrent qbittorrent-wg (10.99.0.3)
  └── initramfs preboot client (10.99.0.4)
```

- `vps0`: `public-exposure-server-wg` is host-network Compose. It creates
  `pubexp-server0`, applies the kernel DNAT mappings, clamps TCP MSS, and runs
  `scripts/mtu-watch.sh`. All host rules are lifecycle-bound to the container.
- `srv0`: `public-exposure-client-wg` is a host-network Compose sidecar. It is
  deliberately outside K3s so it stays up when the cluster is down; that is what
  makes remote LUKS unlock possible.
- `targets/vps0/compose/files/public-exposure/forwards.conf` is the port map:
  preboot SSH `8887 → 10.99.0.4:22`, qBittorrent `56881/tcp+udp → 10.99.0.3`, and
  the remote-access VPN `51820/udp → 10.99.0.2:51830`.
- `scripts/mtu-watch.sh` probes the peer's outer path MTU and sets the tunnel MTU to
  `path - 80`, clamped to 1200–1420. The configs set `MTU = 1280` as the baseline;
  both entrypoints clamp TCP MSS. **Do not remove the watcher without measuring the
  real path-MTU range**; if the path is stable, a conservative static MTU is the only
  simpler alternative.
- `scripts/public-exposure-keygen.sh` generates the hub/client/qBittorrent/preboot
  keys and both confs. `--force` rotates every client. It writes the vps0 hub conf
  under `config/vps0/public-exposure/` for copying to vps0.
- `scripts/preboot.sh public-exposure` installs the initramfs client so dropbear can
  be reached over the tunnel before the LUKS root is unlocked.

## Remote-access VPN

```text
client → vps0 :51820/udp
       → public-exposure tunnel
       → srv0 :51830/udp
       → AmneziaWG ra-amneziawg0 (10.100.0.0/24)
```

- `targets/srv0/k3s-base/templates/vpn.yaml` runs the AmneziaWG server as a
  host-network pod. The keygen init container creates the server/client profiles on
  `remote-access-amneziawg-pvc`; client names come from
  `REMOTE_ACCESS_AMNEZIAWG_CLIENTS`.
- Full-tunnel client traffic is masqueraded; cluster-destined traffic keeps the real
  client source so NetworkPolicies and the edge see it.
- `remote-access-dns` binds `10.100.0.1:53` only. It answers
  `*.<SERVICES_DOMAIN>` with the VPN address and forwards everything else to the
  host resolver.
- `conn-notify` watches the userspace UAPI socket and posts to ntfy when a peer comes
  online. Keep it; it is the VPN connection notification.
- Fetch a client profile on an unlocked host with
  `bash scripts/remote-access-client.sh <client>`.
- Clients must support AmneziaWG; vanilla WireGuard clients cannot use this profile.

## Checks

```bash
# On vps0
wg show pubexp-server0

# On srv0
wg show pubexp-client0
ip -4 addr show ra-amneziawg0
ip route | grep 10.100.0.0/24
```

For path-MTU issues, inspect the `mtu-watch` logs on both tunnel containers before
changing the MTU. For a failed public route, verify the vps0 TCP router, the srv0
`websecure-proxy` listener, and the `edge-public-tls` certificate in that order.
