---
id: decision/storage/state-snapshots
title: Backups are daily snapshots
appliesTo:
  - srv0/ops/backups
  - srv0/apps/dscpln/fl0w
  - script/state-restore
---
The State Backups task runs in FL0W and writes a timestamped rsync snapshot under `state_backups/snapshots/` every day. Each snapshot contains the `auto-backup=true` PVCs under `app-data/`, consistent Postgres/SQLite dumps under `db-dumps/`, the srv0/vps0 Compose state under `compose/`, and a `manifest.json`. Raw DB files/dirs are replaced by the dumps; rebuildable caches/logs are excluded. Only the newest 2 snapshots are kept; unchanged files are hardlinked from the previous one.

Restore is outside the app: `scripts/state-restore.sh list`, `restore`, `db`, and `compose`. The app is backup-only, so a broken app cannot block recovery.
