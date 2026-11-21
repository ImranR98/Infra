# Observability, alerting, and detection

The observability stack is intentionally kept even though it is not required to run
the apps. It uses in-cluster storage and a small set of dashboards.

## Metrics and logs

- **k8s-monitoring** (`base`) deploys Alloy collectors, the Alloy operator,
  kube-state-metrics, and node-exporter. It scrapes cluster/host metrics and tails pod
  logs from each node's `/var/log` (read-only host mount, `spc_t` for SELinux).
- **Prometheus** is a single Deployment with a 200Gi `nfs-apps` PVC and 180-day
  retention; Alloy remote-writes to it.
- **Loki** runs in SingleBinary mode on `nfs-apps` with 180-day retention; Alloy ships
  pod logs to it.
- **Grafana** runs on a 5Gi `local-apps` PVC, uses Authelia OIDC, and provisions:
  - the six dotdc Kubernetes dashboards;
  - the Kubernetes logs dashboard;
  - the Falco overview/health dashboards.
- **infra-health-exporter** exports app health signals used by the dashboards/alerts.

Grafana is at `grafana.<SERVICES_DOMAIN>`. Prometheus and Loki are internal Services;
use Grafana Explore or `kubectl port-forward`.

## Alerting

- Grafana file-provisions contact points, rules, policies, and templates from
  `targets/srv0/k3s-base/files/alerting/`.
- The contact point posts to the in-cluster **ntfy** Service with the write-only
  token; ntfy is also a user-facing app at `ntfy.<SERVICES_DOMAIN>`.
- **Logtfy** runs on `srv0` and `vps0`, tails journal/container/Traefik logs, and
  posts selected events to ntfy (SSH logins, Authelia logins, geoblock decisions,
  public-exposure preboot handshakes).
- **public-exposure-watch** prints one line per preboot-client handshake so Logtfy can
  alert on a remote unlock.
- The Renovate CronJob posts a best-effort PR summary to ntfy after each run.

## Dashboards and operational UIs

| UI | Host | Notes |
|---|---|---|
| Grafana | `grafana.<SERVICES_DOMAIN>` | Authelia OIDC; dashboards + alerts |
| Headlamp | `k8s.<SERVICES_DOMAIN>` | Read-only Kubernetes UI via a scoped ClusterRole |
| Dozzle | `docker.<CLOUD_SERVICES_DOMAIN>` | vps0 container logs; read-only Docker socket proxy |
| Uptime Kuma | `uptime.<CLOUD_SERVICES_DOMAIN>` | vps0 service uptime checks |
| CrowdSec Web UI | `crowdsec.<SERVICES_DOMAIN>` / `crowdsec.<CLOUD_SERVICES_DOMAIN>` | LAPI dashboards on both edges |
| ntfy | `ntfy.<SERVICES_DOMAIN>` | Notification service for apps and alerts |

## Falco and OpenCanary

- **Falco** is a modern-eBPF runtime sensor in `base`. It watches syscalls (CrowdSec
  covers HTTP/L7), writes JSON events, and exposes metrics to Alloy. Custom rules live
  in `targets/srv0/k3s-base/files/falco/custom-rules.yaml`; the
  `falco-exception-triage` skill documents the exception workflow.
- **OpenCanary** is a hostPort honeypot in `apps` (`21/3306/5000/8082/9418`). It has a
  restricted egress policy and posts alerts to an external `ntfy.sh` topic; it is not
  part of the Authelia/CrowdSec edge.

## Retention and failure behavior

Prometheus and Loki keep 180 days; Grafana/Loki/Prometheus are backed by the NFS and
local storage classes described in [Platform: storage](platform.md#storage). Losing
the observability stack does not stop the apps; it removes dashboards and alerts.
