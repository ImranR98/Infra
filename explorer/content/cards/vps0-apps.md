---
id: vps0/apps
title: Public & cloud apps
summary: "The Compose app catalog on vps0. Public apps on the base domain, SSO apps on the cloud domain."
tags: [apps, updates]
---
These services are deliberately unglamorous: one Compose file, one image per service, one Traefik router per hostname. The security posture is expressed in the labels — which middlewares run, which entrypoint is used, and whether the hostname is public or cloud.

Renovate owns every image. There is no watchtower on vps0. Image updates arrive as Infra digest PRs; merging one is inert until a Compose deploy.
