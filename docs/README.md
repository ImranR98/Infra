# Infra docs

The handbook for this homelab. `AGENTS.md` is the short rulebook for agents and
contributors; these pages explain how the system works and how to operate it.

## Targets

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s + public-exposure Compose sidecar | Main home server; most workloads |
| `vps0` | Compose | Public VPS; Traefik edge, public-exposure hub, public apps |
| `bigpc` | Compose | Desktop; llama.cpp ROCm, D4TA archive agent, Syncthing |
| `pc` | Compose | Desktop; llama.cpp SYCL, Syncthing, optional commented ComfyUI |
| `rpi` | Compose | Pi 400 webcam → go2rtc → Frigate on `srv0` |

## Reading order

1. [Architecture](architecture.md) — targets and request paths
2. [Public edge](public-edge.md) — TLS, Authelia, CrowdSec, geoblock
3. [Tunnels](tunnels.md) — public-exposure WireGuard and remote-access VPN
4. [Platform](platform.md) — K3s, multi-node, storage, hardware, resource tiers
5. [Observability](observability.md) — metrics, logs, alerts, dashboards
6. [Apps](apps.md) — inventory, D4TA, backup labels, onboarding
7. [Configuration](configuration.md) — config tree, secrets, host facts
8. [Operations](operations.md) — first boot, deploy, updates, backups, maintenance
9. [Decisions](decisions.md) — invariants and tradeoffs

## Quick answers

| Question | Go to |
|---|---|
| How do I deploy a target? | [Operations: deploy](operations.md#deploy) |
| How do I add an app? | [Apps: adding an app](apps.md#adding-an-app) |
| How do I restore a backup? | [Operations: backups](operations.md#backups) |
| Why NFS and `local-apps`? | [Platform: storage](platform.md#storage) |
| How does public traffic reach srv0? | [Architecture](architecture.md#request-paths) |
| How do I add a public hostname? | [Public edge](public-edge.md#adding-a-public-app) |
| How do I add a K3s node? | [Platform: multi-node](platform.md#multi-node) |

Docs describe the current system; the templates, scripts, and config templates are
authoritative if they disagree.
