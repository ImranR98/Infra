---
id: vps0/service/traefik
title: Traefik (vps0)
summary: "The public reverse proxy: host routers, TLS-ALPN certificates, CrowdSec, geoblock, and the home tunnel file provider."
tags: [network, auth]
---
vps0's Traefik is the only public TLS terminator for base-domain apps. It discovers local services from Docker labels and reads the `traefik_dynamic` file provider for the hosts that tunnel to srv0.

The home routes use `tls.passthrough` and PROXY protocol v2, so srv0's Gateway terminates their TLS. The forwarded-headers trust list restores real client IPs for Cloudflare-proxied hosts; CrowdSec reads the access log through the socket proxy.
