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
- **Single CLI**: `ansible-playbook` is the only entry point — no inventory anywhere: generic ops run on the machine you are on (the target is its hostname, `-e target=` overrides), target-specific ops via target-root playbooks (`targets/<t>/*.yaml`); a few retained payload scripts run directly on their target (PVC backup/restore, node-IP update).
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously.

## Quick start

```bash
# Install prerequisites (Docker, yq, jq, python3, go, ansible-core, helm) — an Ansible playbook
# (if ansible-playbook itself is missing, bootstrap it first: sudo dnf|apt install ansible-core)
ansible-playbook ansible/playbooks/prereqs.yaml

# Create your variables file from the template (plain YAML, gitignored under secrets/ — no encryption)
cp targets/<target>/VARS.template.yaml secrets/VARS.<target>.yaml   # then fill in real values
# srv0: the same secrets/VARS.srv0.yaml is passed to helm as the chart's values file

# Validate your configuration
ansible-playbook ansible/playbooks/validate.yaml

# Deploy compose / k3s
ansible-playbook ansible/playbooks/compose_install.yaml
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=base
ansible-playbook targets/srv0/helm_apply.yaml -e helm_scope=apps

# Check for updates (opens Renovate PRs on GitHub)
ansible-playbook ansible/playbooks/renovate.yaml
```

Extra vars ride `-e key=value` (e.g. `-e target=vps0` to point a generic playbook at another target's files); `--check` dry-runs everything. Run playbooks from the repo root (roles paths in `ansible/ansible.cfg` are config-relative).

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
