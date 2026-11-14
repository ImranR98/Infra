---
id: srv0/base/local-apps
title: local-apps — the local twin of nfs-apps
summary: "A dedicated local-path-provisioner provides RWO host-directory volumes with the same <namespace>/<pvc> layout as nfs-apps."
tags: [storage]
---
`local-apps` is the local counterpart of `nfs-apps`: same purpose (app data), same `<namespace>/<pvc>` directories under `~/infra_state/k3s_live_state/app-data`, but mounted from the host filesystem instead of NFS.

A dedicated `local-path-provisioner` (v0.0.37, not the K3s addon) runs on the `hostpath-main` node. The StorageClass uses:

- `pathPattern: {{ .PVC.Namespace }}/{{ .PVC.Name }}/` — the existing directories are reused; no data copy.
- `nodeAffinityKey: infra.local/hostpath-main` + `allowedTopologies` — PVs are pinned by label, never by hostname.
- `defaultVolumeType: local`, `reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer`, `ReadWriteOnce`.

It is not database-specific: any single-node workload that needs a real POSIX filesystem can use it. SQLite databases are the main consumers because NFS's per-lock cache flush stalls and corrupts them. Postgres and the observability stores (Loki, Prometheus) remain on `nfs-apps` with the measured NFS cost accepted; bulk and shared data also stays there.
