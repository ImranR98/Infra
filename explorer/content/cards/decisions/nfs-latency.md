---
id: decision/storage/nfs-latency
title: NFS for bulk data, local-apps for databases
appliesTo:
  - srv0/base/nfs-server
  - srv0/base/csi-driver-nfs
  - srv0/base/local-apps
  - srv0/apps/media/navidrome
  - srv0/apps/media/frigate
  - srv0/apps/productivity/open-webui
---
App data lives under one tree, `~/infra_state/k3s_live_state/app-data`, with two mount backends:

- `nfs-apps` (default): RWX through the in-cluster NFS server. Media, uploads, Postgres, and anything shared or read-mostly.
- `local-apps` (the local twin): RWO from the host filesystem, provisioned by a dedicated `local-path-provisioner` on the `hostpath-main` node, pinned by label, with the same `<namespace>/<pvc>` layout.

The split is not cosmetic. The NFS client flushes dirty pages and drops the page cache on every fcntl lock (`fs/nfs/file.c` `do_setlk`), which serializes SQLite WAL transactions. Observed before the split: 20–90 s request stalls, `database is locked` / `context deadline exceeded` writes, `database disk image is malformed` in Filebrowser, Jellyfin, Frigate, Radarr, Sonarr and Prowlarr, and a SIGBUS restart of Open WebUI.

NFS remains the right choice for bulk data — ~3× SQLite p95 and 2.6× Postgres latency is the accepted cost there. It is not accepted for the databases themselves, which now use `local-apps`. Immich Postgres still runs with `IGNORE_DATABASE_FSTYPE=true` on NFS.
