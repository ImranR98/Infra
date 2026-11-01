---
id: srv0/apps/dscpln/dscpln-task-runner
title: D$CPLN Task Runner
summary: "The config-driven workflow runner. It runs the scheduled State Backups task and serves the UI behind Authelia."
tags: [dscpln, backup, storage]
---
The Task Runner is the only app that runs as root by design: it needs to read Postgres/Redis-owned PVC data for backups. User-data tasks drop to `MY_UID` through their `run_as` field. The pod uses `spc_t` for the hostPath config checkout and `s0` for the Main tree.

The private `dscpln-config` checkout supplies `config.mjs`, apps, and tools. The backup task is backup-only; restore is `scripts/restic-restore.sh`, deliberately outside the app so a fresh cluster can recover.
