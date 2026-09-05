# Infra

The IaaC system for my homelab.

## Architecture

- `vps0` is a cloud VPS that uses Docker Compose to run public-facing services like [`apps.obtainium.imranr.dev`](https://apps.obtainium.imranr.dev/) and tunnel some requests through to `srv0`.
- `srv0` is a lightweight home server that uses Kuberetes (K3s) to run personal services like [Immich](https://immich.app/).
- `bigpc` is a gaming PC that also serves as a Kubernetes worker node for GPU-accelerated workloads like [Ollama](https://ollama.com/).
- `pc` is a laptop that runs [Syncthing](https://syncthing.net/) (via Docker Compose) to sync files to `srv0`.

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

- Services exposed to the internet through Traefik are protected by [Authelia SSO](https://www.authelia.com/), [Crowdsec](https://www.crowdsec.net/), and [geoblock](https://plugins.traefik.io/plugins/62d6ce04832ba9805374d62c/geo-block).
- Everything is updated through [Renovate](https://www.mend.io/renovate/) (manually invoked on a regular basis).

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