---
id: srv0/base/csi-driver-nfs
title: NFS storage (nfs-apps)
summary: "The CSI driver and default StorageClass that turn the NFS export into Kubernetes volumes."
tags: [storage]
---
`csi-driver-nfs` is the only NFS client in the cluster. It provisions subdirectories under the app-data export and exposes them as the default `nfs-apps` StorageClass.

Volumes are RWX, sizes are advisory, reclaim is Retain, and the driver mounts with NFS 4.2. The hostNetwork node plugin is pinned like the NFS server; this is the storage backbone every app PVC uses.
