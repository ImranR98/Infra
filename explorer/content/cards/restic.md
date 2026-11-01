---
id: concept/backups/restic-repository
title: Restic repository
summary: "One encrypted, deduplicated repository for auto-backup PVCs and Compose state. Restore is deliberately outside the app."
tags: [storage, backup]
---
The repository lives at `state_backups/restic` in the Syncthing-replicated Main/Infra tree. Only srv0 should write it; wait for Syncthing to settle before restoring from a peer.

The Task Runner backup task performs `restic forget --keep-last N --prune` for retention and `restic check --read-data-subset=1%` each run. The password lives in the private `dscpln-config` checkout, not in git. A fresh restore needs the repo, password, and key.
