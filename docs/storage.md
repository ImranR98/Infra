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

- `pvc-backup` (base) is a nightly 3AM CronJob running `scripts/pvc.sh backup --all -y` in-cluster (bitnami/kubectl, hostPath mounts of `$INFRA_ROOT` + `$PVC_BACKUP_DIR`, nodeSelector `infra.local/hostpath-main`). It backs up PVCs with `auto-backup: "true"`; the `backup.infra/exclude` annotation adds tar `--exclude` patterns.
- `pvc.sh` tars the live PVC (no scale-down on backup; scale-down + restore for restore) to the shared `pvc-backup-dest` PV over the `nfs-backup` class — the ROOT of the NFS backups share (= `$PVC_BACKUP_DIR`), so archives land as `<name>.tar.gz` with `__backup_timestamp.txt` inside.
- The CronJob sets **`PVC_POD_UID=0`** so the backup pod can archive PVCs owned by fixed non-`MY_UID` users (Postgres/Redis). The backup pod runs as root with pod-level `level: s0`; the archive is written over NFS with `no_root_squash`.
- `pvc.sh` knobs: `PVC_POD_UID` (0 for root backups), `PVC_BACKUP_TIMEOUT` (default 900s), `PVC_RESTORE_TIMEOUT` (900s), `PVC_BACKUP_THROTTLE` (1 = ~10 MB/s, 0 = unrestricted). The restore pod uses `debian:bookworm-slim` and `tar --numeric-owner` to preserve UIDs.
- Restore scales down every Deployment/StatefulSet that references the PVC (replica counts recorded), waits for pods, restores via a privileged-enough temp pod, then scales back up. `--all` does a bulk scale-down first. Backup and restore pods need pod-level `seLinuxOptions.level: s0`.
- App PVCs are NFS/RWX and `pvc.sh` has no Longhorn/node-placement logic; backup/restore pods can run anywhere.

## NFS performance note

NFS is excellent for read-heavy/sequential workloads and media. SQLite/WAL and Postgres are latency-sensitive: on the migrated NFS volumes they are measurably slower than the old block storage (the benchmark measured ~3× SQLite p95 and ~2.6× Postgres latency under load). The full-NFS migration was chosen with that tradeoff accepted. The Immich Postgres image requires `IGNORE_DATABASE_FSTYPE=true` to start on NFS; it is set in `immich.yaml`.
