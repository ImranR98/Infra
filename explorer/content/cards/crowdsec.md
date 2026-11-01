---
id: srv0/base/crowdsec
title: CrowdSec
summary: "L7 intrusion prevention. Agent, LAPI, and AppSec in one chart, with the web UI and per-service whitelists."
tags: [security]
---
CrowdSec watches Traefik's access log through the bouncer plugin and AppSec. The web UI is a separate deployment with its own LAPI machine credentials; the registration is a one-time manual step.

The whitelist configs are deliberate: Plausible and the CrowdSec Web UI are SPAs, and their stats API bursts trip crawl scenarios. The whitelists are scoped by hostname, scenario, verb, and path.
