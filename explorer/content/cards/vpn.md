---
id: srv0/base/vpn
title: Remote access VPN
summary: "A host-network AmneziaWG server for full-tunnel access, with a DNS pod that keeps service URLs working."
tags: [network, auth]
---
The VPN is a host-network pod on the external-exposed node. It runs the userspace `amneziawg-go` implementation, creates `ra-amneziawg0`, and masquerades full-tunnel client traffic. vps0 DNATs `51820/udp` to `10.99.0.2:51830` over the public-exposure tunnel.

The companion DNS pod binds only `10.100.0.1:53` and answers `*.$SERVICES_DOMAIN` with the tunnel address, so clients keep using normal service URLs. Client profiles are fetched with `scripts/remote-access-client.sh`.
