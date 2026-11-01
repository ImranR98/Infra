---
id: vps0/service/crowdsec
title: CrowdSec (vps0)
summary: "The edge LAPI/AppSec instance. A single container watches Traefik logs and enforces the bouncer decisions."
tags: [security]
---
CrowdSec runs as one container with the Traefik collection, AppSec virtual patching, and a bouncer key registered from `BOUNCER_KEY_TRAEFIK`. The access log is mounted read-only from the Traefik state directory.

The SPA whitelists are deliberate: Plausible and the CrowdSec Web UI fetch stats in bursts and trip crawl scenarios. They are scoped by hostname, scenario, verb, and path.
