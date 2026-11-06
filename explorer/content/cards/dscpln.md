---
id: srv0/apps/dscpln/fl0w
title: FL0W
summary: "Scheduled tasks and file pipelines in one app. It runs the State Backups task and serves both legacy views."
tags: [fl0w, backup, storage, pipelines]
---
FL0W is the only app that runs as root by design: it needs to read Postgres/Redis-owned PVC data for backups. User-data tasks drop to `MY_UID` through their `run_as` field. The pod uses `spc_t` for the hostPath config checkout and `s0` for the Main tree.

The private `fl0w-config` checkout supplies `config.mjs`, pipeline jobs and tools. Task jobs and pipeline jobs share the unified `/api/jobs` model; the complete legacy views stay at `/tasks/` and `/pipelines/`. The backup task is backup-only; restore is `scripts/restic-restore.sh`, deliberately outside the app so a fresh cluster can recover.

D$CPLN, W@TXT and DA5H are separate apps with their own repos, images and private config checkouts.
