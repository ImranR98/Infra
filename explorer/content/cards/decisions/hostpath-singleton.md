---
id: decision/cluster/hostpath-singleton
title: hostpath-main is a singleton
appliesTo:
  - srv0/cluster
  - srv0/base/host-volumes
  - srv0/base/nfs-server
---
The Main tree lives on one node. The static hostpath PVs and the NFS export assume a single owner, so `infra.local/hostpath-main=true` must be on exactly one node. `k3s-join.sh --hostpath-main` replaces the owner; it does not add a second.

`ai-data-pv` is a second hostpath exception, pinned by `kubernetes.io/hostname=bigpc` because it is local desktop AI data rather than a GPU selector. Its consumer mounts `subPath: llama`.

Pods are pinned by the claim's `nodeAffinity`, not by a pod `nodeSelector`. That keeps the scheduling rule attached to the data.
