---
id: srv0/base/traefik
title: Traefik
summary: "The Kubernetes Gateway implementation. Host ports, no Service, shared middleware chain."
tags: [network, auth]
---
Traefik runs as a pod-network DaemonSet with hostPorts 80/443/8443 and no Service. The CNI hostPort DNAT is the only way in, which preserves real client sources for LAN/VPN traffic.

The chart's placeholder Gateway stays disabled; the repo owns the Gateway and HTTPRoutes. Middlewares live in `base` because Traefik resolves ExtensionRef filters only in the route namespace.

The middleware chain is the auth story: geoblock, CrowdSec bouncer, Authelia forward-auth, plus app-specific rate limits. Plugin versions are pinned and Renovate-managed.
