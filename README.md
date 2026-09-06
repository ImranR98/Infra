# Infra

The IaaC system for my homelab and other devices.

## Architecture

- `vps0` is a cloud VPS that uses Docker Compose to run public-facing services like [`apps.obtainium.imranr.dev`](https://apps.obtainium.imranr.dev/) and tunnel some requests through to `srv0`.
- `srv0` is a lightweight home server that uses Kuberetes (K3s) to run personal services like [Immich](https://immich.app/).
- `bigpc` is a gaming PC that also serves as a Kubernetes worker node for GPU-accelerated workloads like [Ollama](https://ollama.com/).
- `pc` is a laptop that runs [Syncthing](https://syncthing.net/) (via Docker Compose) to sync files to `srv0`.
- `rpi` is an SBC that streams a live camera feed to [Frigate](https://frigate.video/) on `srv0`.

<p align="center">
  <img src="./architecture.svg" alt="Infra architecture overview" width="800"/>
</p>

- Services exposed to the internet through Traefik are protected by [Authelia SSO](https://www.authelia.com/), [Crowdsec](https://www.crowdsec.net/), and [geoblock](https://plugins.traefik.io/plugins/62d6ce04832ba9805374d62c/geo-block).
- Everything is updated through [Renovate](https://www.mend.io/renovate/) (run daily on a schedule from `srv0`; review/merge the PRs it opens).

## Project Goals

- **Infrastructure as Code**: Everything should be declarative and automated, using standard tooling wherever possible. Custom scripts should be minimal and only where necessary.
- **Universal CLI**: `task <target>:<command>` is the entry point for everything (dispatch via [Task](https://taskfile.dev); `task default` prints examples, `task --list-all` lists every command).
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously.

## Quick start

```bash
# Install prerequisites (task, Docker, yq, envsubst, jq, python3, python3-dotenv, go)
# (no task installed yet? `bash commands/prereqs.sh` works the same)
task prereqs

# Create your variables file from the template (dotenv format)
cp targets/<target>/VARS.template.env secrets/VARS.<target>.env
# Edit secrets/VARS.<target>.env with your secrets and settings

# Validate your configuration
task <target>:validate

# Deploy
task <target>:compose:install
task <target>:k3s:group:base:apply
task <target>:k3s:group:apps:apply

# Check for updates (opens Renovate PRs on GitHub; no target needed)
task renovate
```

Commands that take arguments pass them after `--`, e.g. `task srv0:k3s:deploy -- traefik diff`.

## Migrating from the old `./infra.sh` CLI

`./infra.sh` (and the bash dispatcher behind it) was replaced by `task` + a Python VARS validator (`lib/vars_validator.py`), with environment loading folded into `lib/common.sh`, and the VARS files moved from bash exports (`VARS.*.sh`) to dotenv (`VARS.*.env`, converted on each machine by a one-time script that has since been deleted). Command mapping is 1:1 — `./infra.sh srv0 compose install` became `task srv0:compose:install`. See the "Rollback" section in AGENTS.md.

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
