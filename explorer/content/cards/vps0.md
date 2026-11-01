---
id: vps0
title: vps0
summary: "The public edge; Traefik, auth, and the tunnel hub."
tags: [primary, network, auth, updates]
facts:
  - label: Orchestrator
    value: Docker Compose
  - label: Public zone
    value: $BASE_SERVICES_DOMAIN
  - label: SSO zone
    value: $CLOUD_SERVICES_DOMAIN
---
vps0 is the only machine with a public IP. It does three jobs:

1. **Terminate public TLS** for the base-domain apps and the cloud/SSO apps.
2. **Guard the edge** with CrowdSec, geoblock, and Authelia.
3. **Forward home hostnames** (`home.$BASE_SERVICES_DOMAIN` and `*`) over the public-exposure tunnel without terminating srv0's TLS.

The tunnel is the important boundary. vps0 sends HTTPS through with `tls.passthrough` and PROXY protocol v2; srv0's Traefik sees the real client source through the `websecure-proxy` listener. vps0 never holds the private keys for home services.
