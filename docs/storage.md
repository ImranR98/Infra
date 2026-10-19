# Storage

## App data — NFS (`nfs-apps`)

- The `nfs-server` pod (base) exports host paths; `csi-driver-nfs` mounts them. The **app-data export** is `/exports/apps` → `{{ .Values.INFRA_ROOT }}/current_target/k3s_live_state/nfs-apps`, with `no_root_squash` (needed by CSI subdir creation and Postgres chowns).
- The dynamic StorageClass **`nfs-apps`** is the **default** (`storageclass.kubernetes.io/is-default-class: "true"`). It provisions `subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}`, `mountPermissions: "0777"`, `reclaimPolicy: Retain`, `onDelete: retain`, `volumeBindingMode: Immediate`, `allowVolumeExpansion: false` (sizes are advisory; NFS has no quota).
- Migrated PVCs use **`ReadWriteMany`** so backup/restore pods can run on any node. The CSI driver is the only NFS client (hostNetwork node plugin); `nfs-server` ingress is allowlisted to the LAN CIDR (`allow-nfs-ingress`), all mounts use `nfsvers=4.2`.
- `local-path` and `nfs-backup` remain available but are not defaults. The old Longhorn SCs/PVs/volumes are gone; rollback is via the tar backups, not Longhorn snapshots.

## Shared media / static host paths

- `host-volumes` (base) defines the static `hostpath` PV/PVC pairs for the Main tree (media, music, documents, WhatsApp, backups, infra) pinned by `infra.local/hostpath-main=true`.
- The NFS media shares (`music`, `jellyfin-tv`, `jellyfin-youtube`, `arrstack-media`, `frigate`, `backups`, `code-sandbox`) are static PVs using the `nfs`/`nfs-backup` class names; they are not dynamically provisioned.
- Media deliberately stays on NFS (Frigate recordings, Jellyfin libraries, Immich external library) so pods can move nodes.

## Backups

- The **State Backups** D$CPLN app (`apps/state-backup`) is the active backup system. It runs on a schedule (default Sundays 04:00) and has a manual **Run now**. One encrypted, deduplicated restic repository at `state_backups/restic` contains:
  - every PVC labelled `auto-backup=true` under `current_target/k3s_live_state/nfs-apps/<namespace>/<pvc>`,
  - the srv0 Compose state,
  - the vps0 Compose state, fetched over SSH with the existing key.
- The app runs as root in the `apps` namespace so it can read the Postgres/Redis-owned PVC data; it mounts the Infra tree read-only and only `state_backups/` writable. The vps0 key is the `state-backup-vps0-ssh` Secret (and a recovery copy under `config/state-backup-vps0/`).
- `retention` maps to `restic forget --keep-last N --prune` (default 7). Each run also does `restic check --read-data-subset=1%`.
- The repository lives in the Syncthing-replicated `Main/Infra` tree. Only srv0 should write it; wait for Syncthing to settle before restoring from a peer. The State Backups app keeps the repo root group-owned by `MY_UID` with the setgid bit, so every restic-created directory/file is readable by Syncthing; it also performs the one-time group migration of an existing repo. `restic/locks` is intentionally excluded from Syncthing.
- Syncthing's database/logs (`index-v2`) live on srv0 local disk at `~/.local/share/syncthing-data`, not on the `syncthing-config-pvc`. The config, certs and keys stay on the NFS PVC and are included in backups; the index is disposable and excluded from them.
- Restore is intentionally outside the app: `scripts/restic-restore.sh list`, `... pvc <name> [snapshot] [--live]`, and `... compose srv0|vps0 [snapshot] [--live]`. The script works on a fresh cluster and uses the repo/password/key directly.
- The old tar path remains only as rollback during the transition: `pvc-backup`/`scripts/pvc.sh` and `compose_state_backups/` are legacy. `k3s_state_backups/` is the old PVC-tar directory. Remove them after the new restic restore is verified.
- The restic password defaults to a built-in value in the app; it is configurable in the app Settings. If changed, record it off-cluster — a fresh restore needs it. Changing it after the repo exists requires `restic key add`/`restic key remove`; the app will not silently recreate the repo.

## NFS performance note

NFS is excellent for read-heavy/sequential workloads and media. SQLite/WAL and Postgres are latency-sensitive: on the migrated NFS volumes they are measurably slower than the old block storage (the benchmark measured ~3× SQLite p95 and ~2.6× Postgres latency under load). The full-NFS migration was chosen with that tradeoff accepted. The Immich Postgres image requires `IGNORE_DATABASE_FSTYPE=true` to start on NFS; it is set in `immich.yaml`. Prometheus also runs on `nfs-apps`; it logs an unsupported-filesystem warning (accepted, mirroring the old Mimir PVC) and its TSDB starts fresh with the Mimir cutover.
