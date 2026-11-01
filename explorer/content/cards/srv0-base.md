---
id: srv0/base
title: Platform · base
summary: "The cluster foundation. Gateway and certificates, storage, auth and security, observability, node lifecycle, and the update controller."
tags: [platform]
---
The `base` namespace is the platform contract. Everything in `apps` can assume these pieces exist:

- a Gateway with three listeners and two shared certificates
- an NFS server, the `nfs-apps` default StorageClass, and static host-path PVs
- Authelia, CrowdSec, Falco, and the NetworkPolicy baseline
- Alloy/Prometheus/Loki/Grafana and ntfy
- the generic device plugin and node-upgrade controller
- the Renovate CronJobs

Most components are file-scoped: opening one shows the resources it owns, the images it runs, and the other components it references.
