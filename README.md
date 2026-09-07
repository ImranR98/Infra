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
- **Single CLI**: `infra` (a thin wrapper over `ansible-playbook`) is the entry point — no inventory anywhere, and the target is **always explicit**: target-selecting ops take it as `infra <target> <op>` (compose/validate/helm/pvc), machine-local ops run on the machine you are on and take no target; a few retained payload scripts run directly on their target (PVC backup/restore, node-IP update).
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously.

## Quick start

```bash
# Optional one-time: make `infra` available from anywhere
ln -s ~/Main/Infra/infra ~/bin/infra

# Install prerequisites (Docker, yq, jq, python3, go, ansible-core, helm) — an Ansible playbook
# (if ansible-playbook itself is missing, bootstrap it first: sudo dnf|apt install ansible-core)
infra prereqs

# Create your variables file from the template (plain YAML, gitignored under secrets/ — no encryption)
cp targets/<target>/VARS.template.yaml secrets/VARS.<target>.yaml   # then fill in real values

# Validate your configuration (the target is explicit; <target> is e.g. srv0)
infra <target> validate

# Deploy compose / k3s — compose ops must run ON the target machine;
# helm ops target the machine whose k3s chart you mean
infra <target> compose-install
infra <target> helm base
infra <target> helm apps

# Check for updates (opens Renovate PRs on GitHub) — machine-local
infra renovate
```

Extra args ride after the op (`infra vps0 validate -e ...`; `--check` dry-runs everything). Raw `ansible-playbook` works the same from the repo root (the root `ansible.cfg` is auto-discovered there); target-selecting playbooks require `-e target=<t>`, machine-local ones take none.

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
