---
id: srv0/base/nfs-server
title: NFS server & nfs-apps
summary: "The storage backbone. A containerized NFS server exports host paths; csi-driver-nfs makes them the default StorageClass."
tags: [storage]
---
The NFS server is a privileged container because it hosts a kernel NFS server. It exports the app-data tree at `current_target/k3s_live_state/nfs-apps` with `no_root_squash`, which the CSI driver and Postgres chowns require.

`nfs-apps` is the default StorageClass. Volumes are RWX, sizes are advisory, and reclaim is Retain. The CSI driver is the only NFS client; every share uses NFS 4.2.

The tradeoff is deliberate: NFS is excellent for media and sequential reads, but SQLite/WAL and Postgres are latency-sensitive. That is the accepted cost of removing Longhorn.
