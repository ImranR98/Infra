---
id: srv0/base/descheduler
title: Descheduler
summary: "Kept deployed for future nodes; on a single node every run is a no-op."
tags: [cluster, updates]
---
The descheduler runs as a CronJob every ten minutes. Its one profile is a taint safety net: `RemovePodsViolatingNodeTaints` with `nodeFit`, so a future tainted node only evicts pods that fit elsewhere. No node carries a taint today, so the runs complete without evicting anything.

It is kept deliberately for future multi-node work. It does not use a utilization profile, so it works without metrics-server.
