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
App data lives on the NFS-backed `nfs-apps` StorageClass. A distributed storage layer buys no availability on a single node, so it is left out: no control plane, no iSCSI, no per-volume engines.

The measured cost is real: roughly 3× SQLite p95 and 2.6× Postgres latency under disk load. It is accepted because NFS is excellent for media and sequential reads, and the backup/restore path is simpler. Immich Postgres needs `IGNORE_DATABASE_FSTYPE=true` to start on NFS.
