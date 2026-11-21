# Infra

The IaC system for my homelab and other devices.

## Targets

| Target | Orchestrator | Role |
|---|---|---|
| `srv0` | K3s + public-exposure Compose sidecar | Main home server; most workloads |
| `vps0` | Compose | Public VPS; Traefik edge, public-exposure hub, public apps |
| `bigpc` | Compose | Desktop; llama.cpp ROCm, D4TA archive agent, Syncthing |
| `pc` | Compose | Desktop; llama.cpp SYCL, Syncthing, optional commented ComfyUI |
| `rpi` | Compose | Pi 400 webcam → go2rtc → Frigate on `srv0` |

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

Design goals: declarative IaC, layered security, least privilege, and automated
updates/backups. The details live in `docs/`.

## Start here

| Doc | What it covers |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Targets, request paths, data/control flow |
| [`docs/public-edge.md`](docs/public-edge.md) | TLS, Authelia, CrowdSec, geoblock, public hosts |
| [`docs/tunnels.md`](docs/tunnels.md) | Public-exposure WireGuard, remote-access VPN, preboot |
| [`docs/platform.md`](docs/platform.md) | K3s, multi-node, storage, hardware, resource tiers |
| [`docs/observability.md`](docs/observability.md) | Metrics, logs, alerts, dashboards, Falco/OpenCanary |
| [`docs/apps.md`](docs/apps.md) | App inventory, D4TA, backup labels, optional ComfyUI |
| [`docs/configuration.md`](docs/configuration.md) | Config tree, secrets, host facts, validation |
| [`docs/operations.md`](docs/operations.md) | First boot, deploy, updates, backups, maintenance |
| [`docs/decisions.md`](docs/decisions.md) | Invariants and tradeoffs |

`AGENTS.md` is the short rulebook for agents and contributors.

## Quick start

```bash
bash scripts/prereqs.sh
bash scripts/init-config.sh srv0 --detect   # vps0/bigpc: drop --detect
# Fill config/<target>/ from config_template; see docs/configuration.md
bash scripts/validate.sh srv0
# Deploy: docs/operations.md#deploy
```

Note that while LLMs are used in development, the LLM isn't the one putting its data
on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology)
and is used like one.
