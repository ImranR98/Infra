# Infra

The IaC system for my homelab and other devices.

Targets, request paths, and design goals: [Architecture](docs/architecture.md).

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

Docs index: [docs/README.md](docs/README.md). Rulebook: [AGENTS.md](AGENTS.md).

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
