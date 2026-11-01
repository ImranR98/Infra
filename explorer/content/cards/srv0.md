---
id: srv0
title: srv0
summary: "The home K3s control plane; apps and data."
tags: [primary, network, storage, auth, updates]
facts:
  - label: Orchestrator
    value: K3s + Helm
  - label: Releases
    value: srv0-base · srv0-apps
---
srv0 is deliberately boring at the cluster level: one K3s server, one NFS server, one Gateway, and an app catalog expressed as Helm templates. The interesting work is in the seams — the public-exposure client, the storage pinning, the auth chain, and the update routine.

The apps-and-data tour covers the platform, apps, node provisioning, accelerators, NFS, and backups; the operations tour covers Renovate, CI, monitoring, and remote access.

The Compose sidecar is the one piece that is not Kubernetes. It owns `pubexp-client0` (`10.99.0.2`) and is deliberately lifecycle-bound: stopping the container removes the interface.
