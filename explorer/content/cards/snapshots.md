---
id: concept/backups/state-snapshots
title: State snapshots
summary: "Daily rsync snapshots of labelled PVCs and Compose state. Restore is deliberately outside the app."
tags: [storage, backup]
---
Snapshots live under `state_backups/snapshots/<UTC timestamp>/` in the Syncthing-replicated Main/Infra tree. Each snapshot contains `app-data/`, `db-dumps/`, `compose/`, and `manifest.json`; only the newest 2 are kept. Unchanged files are hardlinked from the previous snapshot with `rsync --link-dest`.

The backup task auto-discovers SQLite (header) and Postgres (`PG_VERSION` plus the running pod) databases inside the labelled PVCs; the DB files/dirs are excluded from `app-data` and replaced by logical dumps. There is no repository password or special format; the trade-off is plaintext snapshots in the Syncthing tree.
