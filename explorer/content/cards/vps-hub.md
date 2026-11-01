---
id: vps0/service/public-exposure-server-wg
title: Public-exposure hub
summary: "The WireGuard hub on vps0. It creates the tunnel interface, applies DNAT, and removes every host effect on exit."
tags: [network]
---
The hub runs with host networking and `NET_ADMIN`. Its entrypoint creates `pubexp-server0` (`10.99.0.1`), applies port forwards from `forwards.conf`, and traps SIGTERM to remove the interface, DNAT, and firewall rules.

Only selected ports are forwarded. Home HTTPS goes to `10.99.0.2:8443` with PROXY protocol v2 and TLS passthrough; qBittorrent keeps real peer sources because its flows are not masqueraded.
