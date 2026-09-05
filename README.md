# Infra

The IaaC system for my homelab.

## Architecture

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

- `vps0` is a cloud VPS that runs a Docker Compose stack and runs critical public-facing services, like [`apps.obtainium.imranr.dev`](https://apps.obtainium.imranr.dev/), for which downtime is unaccaptable.
- `srv0` is a lightweight home server that runs a Kuberetes stack and runs personal services, like [Immich](https://immich.app/), for which occasional downtime is acceptable.
- `bigpc` is a gaming PC that also serves as a Kubernetes worker node for GPU-accelerated workloads like [Ollama](https://ollama.com/).
- `pc` is a laptop that runs [Syncthing](https://syncthing.net/) via Docker Compose, to sync files to `srv0`.


## Project Goals

- **Infrastructure as Code**: Everything should be declarative and automated, using standard tooling wherever possible. Custom scripts should be minimal and only where necessary.
- **Universal CLI**: `./infra.sh <target> <command>` is the entry point for everything.
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously.

## Quick start

```bash
# Install prerequisites (Docker, yq, envsubst, jq, python3)
./infra.sh <target> prereqs

# Create your variables file from the template
cp targets/<target>/VARS.template.sh VARS.<target>.sh
# Edit VARS.<target>.sh with your secrets and settings

# Validate your configuration
./infra.sh <target> validate

# Deploy
./infra.sh <target> compose install
./infra.sh <target> k3s group base apply
./infra.sh <target> k3s group apps apply
```

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.