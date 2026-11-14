---
id: srv0/base/monitoring
title: Observability
summary: "Alloy collects cluster, host, and pod logs; Prometheus and Loki store them; Grafana alerts to ntfy."
tags: [observability]
---
The k8s-monitoring chart generates the Alloy collectors: cluster metrics, host metrics, and pod logs. Prometheus is the metrics store (180-day retention); Loki holds logs (180-day retention, queryable across the full window via `max_query_length`). Grafana reads both and provisions dashboards and alert rules from files in `k3s-base/files/`.

Both stores remain on `nfs-apps`; their TSDBs are not SQLite and retention/compaction is healthy, so the NFS caveat is accepted for now.

Falco is the runtime sensor: modern eBPF, JSON events to Loki, metrics to Prometheus. It runs as a DaemonSet on the K3s node (`srv0`); the Falco dashboards are provisioned alongside the core alerts. Bigpc is Compose-only, so host sensors cover `srv0` only.
