---
id: srv0/cluster
title: Cluster & hardware
summary: "K3s provisioning, static node labels, optional workers, and the generic device plugin that turns hardware into schedulable resources."
tags: [cluster]
---
The cluster is provisioned only through `scripts/k3s-server.sh` and `scripts/k3s-join.sh`. Those scripts own the installer, the token handling, the sysctls, and the static labels:

- `infra.local/hostpath-main=true` — the one node that owns the Main tree
- `infra.local/external-exposed=true` — the node with the public-exposure tunnel
- `infra.local/noschedule=true:NoSchedule` — an opt-in-only node; only workloads that explicitly tolerate it run there

Hardware is requested as a resource, not selected by a node label. The generic device plugin scans sysfs and `/dev` and advertises `infra.local/intel-gpu`, `amd-igpu`, `amd-dgpu`, `vaapi`, and `conbee`. That is why a workload can move to a different node without changing its manifest.

`bigpc` is an optional, opt-in-only worker. It is not documented as a peer machine; it supplies a discrete AMD GPU to Immich ML and llama.cpp. Normal apps and platform services never tolerate its `noschedule` taint.
