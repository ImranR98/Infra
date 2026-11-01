---
id: decision/storage/restic-backups
title: Backups are backup-only
appliesTo:
  - srv0/ops/backups
  - srv0/apps/dscpln/dscpln-task-runner
  - script/restic-restore
---
The State Backups task runs in the D$CPLN Task Runner and writes one encrypted, deduplicated restic repository at `state_backups/restic`. It captures every `auto-backup=true` PVC and the srv0/vps0 Compose state.

Restore is intentionally outside the app: `scripts/restic-restore.sh` works on a fresh cluster and uses the repo/password directly. The app is backup-only, so a broken app cannot block recovery.
