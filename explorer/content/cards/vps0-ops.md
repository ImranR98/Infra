---
id: vps0/ops
title: vps0 operations
summary: "Uptime, logs, monthly image pruning, and the optional D$CPLN archive agent."
tags: [ops]
---
Operational sidecars on the VPS are small on purpose. The one scheduled host-level task is the monthly `docker-image-prune` systemd timer. The archive agent is optional and behind a Compose profile; it exists so srv0's backup task can pull vps0 Compose state over the private tunnel.

Other Compose targets use the same wrapper. `pc` is one example, but it is intentionally outside these tours.
