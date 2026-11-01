---
id: concept/public-exposure
title: Public-exposure tunnel
summary: "A WireGuard link that carries public traffic from vps0 to srv0 without exposing the LAN or terminating TLS at the edge."
tags: [network, auth]
---
This is not a general VPN. It is a narrow, purpose-built tunnel:

- vps0 owns `10.99.0.1` and DNATs selected public ports into the tunnel.
- srv0 owns `10.99.0.2` through a Compose sidecar.
- Home HTTPS is forwarded with `tls.passthrough` and PROXY protocol v2; srv0's Gateway terminates TLS.
- The MTU is 1340 because the public path is 1420, and both sides clamp MSS.
- All host effects are lifecycle-bound: stopping the container removes the interface, DNAT, and firewall rules.

The result: srv0 can serve public hostnames without a public IP, and vps0 never holds the private keys.
