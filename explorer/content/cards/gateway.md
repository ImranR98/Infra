---
id: srv0/base/gateway
title: Gateway & edge certificates
summary: "One Gateway, three listeners, two shared exact-name certificates."
tags: [network, auth]
---
The Gateway is the security boundary:

- `web:80` is HTTP for Plik only.
- `websecure:443` is LAN/VPN and carries both the public and private certificates.
- `websecure-proxy:8443` accepts PROXY protocol v2 only from `10.99.0.1/32` and carries the public certificate.

`edge-public-tls` lists `PUBLIC_HOSTS` exactly; `edge-private-tls` lists `PRIVATE_HOSTS` and is never attached to the proxy listener. Adding a public app means adding its SAN, re-issuing, and adding the route.
