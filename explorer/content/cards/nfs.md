---
id: srv0/base/nfs-server
title: NFS server & the app-data tree
summary: "The storage backbone. A containerized NFS server exports the app-data tree; csi-driver-nfs makes it the default StorageClass."
tags: [storage]
---
The NFS server is a privileged container because it hosts a kernel NFS server. It exports the app-data tree at `~/infra_state/k3s_live_state/app-data` with `no_root_squash`, which the CSI driver and Postgres chowns require.

`nfs-apps` is the default StorageClass. Volumes are RWX, sizes are advisory, and reclaim is Retain. The CSI driver is the only NFS client; every share uses NFS 4.2.

Its local twin is `local-apps`: the same `<namespace>/<pvc>` layout under the same tree, mounted from the host filesystem (RWO, pinned to the `hostpath-main` node by label). Databases and other lock-sensitive workloads use `local-apps`; NFS stays for bulk and shared data. The tradeoff is deliberate: NFS is excellent for media and sequential reads, but SQLite/WAL and Postgres are latency-sensitive — and SQLite over NFS also corrupts.
