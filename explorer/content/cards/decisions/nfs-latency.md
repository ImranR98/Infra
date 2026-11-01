---
id: decision/storage/nfs-latency
title: Full NFS storage, latency accepted
appliesTo:
  - srv0/base/nfs-server
  - srv0/base/csi-driver-nfs
  - srv0/apps/media/immich
  - srv0/apps/media/frigate
  - srv0/apps/productivity/nextcloud
---
Longhorn was single-node in practice and added a distributed control plane, iSCSI, and per-volume engines for no availability benefit. The app data moved to the NFS-backed `nfs-apps` StorageClass.

The measured cost is real: roughly 3× SQLite p95 and 2.6× Postgres latency under disk load. It was accepted because NFS is excellent for media and sequential reads, and the backup/restore path is simpler. Immich Postgres needs `IGNORE_DATABASE_FSTYPE=true` to start on NFS.
