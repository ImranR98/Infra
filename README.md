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

## Project Goals

- **Infrastructure as Code**: Everything should be declarative and automated, using standard tooling wherever possible. Custom scripts should be minimal and only where necessary.
- **Single CLI**: `infra` (a thin wrapper over `ansible-playbook`) is the entry point used for all deployment, update, and management tasks.
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously. To that end:
  - **[Authelia](https://www.authelia.com/) SSO** guards every service that needs it.
  - **[CrowdSec](https://www.crowdsec.net/) automated threat response** guards all public services.
  - **Geoblocking** is used for services that do not need to be globally accessible.
  - **mTLS** (as opposed to symmetric token-based encryption) is used to protect the FRP tunnel between `srv0` and `vps0` (this prevents certain kinds of MITM attacks).
  - **Restrictive network policies** are used in the `srv0` Kubernetes stack to ensure that pod-to-pod communication is only allowed where necessary.
  - **The Principle of Least Privilege** is applied to containers, with elevated privileges and root runtime user only allowed where necessary. Access to host devices is granted via [CDI](https://docs.docker.com/build/building/cdi/) rather than `privileged: true`.
  - **WireGuard** is used to encrypt node-to-node communication over the K3s overlay network.
  - **Regular update checking** is done via [Renovate](https://www.mend.io/renovate/) (updates are applied manually to avoid unplanned changes).

## Quick start

```bash
# Install prerequisites (Docker, yq, jq, python3, go, ansible-core, helm)
./infra prereqs

# Create your variables file from the template (plain YAML, gitignored under secrets/ — no encryption)
cp targets/<target>/VARS.template.yaml secrets/VARS.<target>.yaml   # then fill in real values

# Validate your configuration (the target is explicit; <target> is e.g. srv0)
./infra <target> validate

# Deploy compose / k3s — compose ops must run ON the target machine;
# helm ops target the machine whose k3s chart you mean
./infra <target> compose-install
./infra <target> helm base
./infra <target> helm apps

# Check for updates (opens Renovate PRs on GitHub) — machine-local
./infra renovate
```

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
