---
id: srv0/base/monitoring
title: Observability
summary: "Alloy collects cluster, host, and pod logs; Prometheus and Loki store them; Grafana alerts to ntfy."
tags: [observability]
---
The k8s-monitoring chart generates the Alloy collectors: cluster metrics, host metrics, and pod logs. Prometheus is the metrics store (180-day retention); Loki holds logs. Grafana reads both and provisions dashboards and alert rules from files in `k3s-base/files/`.

Falco is the runtime sensor: modern eBPF, JSON events to Loki, metrics to Prometheus. Alerts are gated to avoid paging on bigpc being powered off; the Falco dashboards are provisioned alongside the core alerts.
