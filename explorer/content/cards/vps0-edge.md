---
id: vps0/edge
title: Edge & security
summary: "The public entry point. Traefik routes, Authelia protects, CrowdSec watches, and the WireGuard hub forwards home traffic."
tags: [network, auth]
---
The edge is a chain, not a single proxy:

`Internet → Traefik → middlewares (CrowdSec, geoblock, Authelia) → service`

Two zones share the edge. `$BASE_SERVICES_DOMAIN` hosts public apps; `$CLOUD_SERVICES_DOMAIN` hosts SSO-protected apps. The file provider adds the home routes that tunnel to srv0.

The public-exposure hub is a host-network container. It creates `pubexp-server0`, applies DNAT for selected ports, and removes the interface and rules on exit. It never terminates home TLS.
