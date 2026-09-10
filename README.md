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
- **Security**: As the codebase is public and the system runs public-facing services containing highly personal data, security must be taken seriously. To that end:
  - **[Authelia](https://www.authelia.com/) SSO** guards every service that needs it.
  - **[CrowdSec](https://www.crowdsec.net/) automated threat response** guards all public services.
  - **Geoblocking** is used for services that do not need to be globally accessible.
  - **Network policies** are used in the `srv0` Kubernetes stack to ensure that pod-to-pod communication is only allowed where necessary.
  - **mTLS** (as opposed to symmetric token-based encryption) is used to protect the FRP tunnel between `srv0` and `vps0` (this prevents certain kinds of MITM attacks).
  - **The Principle of Least Privilege** is applied to containers, with elevated privileges and root runtime user only allowed where necessary. Access to host devices is granted via [CDI](https://docs.docker.com/build/building/cdi/) rather than `privileged: true`.
  - **Comprehensive Monitoring and Alerting** is done using [Alloy](https://grafana.com/docs/alloy/) + [Mimir](https://grafana.com/oss/mimir/), [Loki](https://grafana.com/docs/loki/latest/), [Grafana](https://grafana.com/), [Ntfy.sh](https://ntfy.sh/) + [Logtfy](https://github.com/ImranR98/Logtfy), [Headlamp](https://headlamp.dev/), [Dozzle](https://dozzle.dev/), and [Uptime Kuma](https://uptimekuma.co/).
  - **A Honeypot ([Opencanary](https://github.com/thinkst/opencanary))** is used to discover intruders. 
  - **Regular update checking** is done via [Renovate](https://www.mend.io/renovate/) (updates are applied manually to avoid unplanned changes).

## Quick start

```bash
# Install prerequisites (Docker, yq, jq, python3, go, helm)
bash scripts/prereqs.sh

# Create your configuration from the template (values.yaml for k3s, compose.env
# for compose, plus extra files like certs and the Authelia users DB):
cp -r targets/<target>/config_template config/<target>   # then fill in real values

# Validate your configuration
bash scripts/validate.sh <target>

# Deploy k3s (the kubeconfig is root-only — unlock it in another terminal first)
bash scripts/kubeconfig-unlock.sh   # Ctrl-C to lock
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml

# Deploy compose
docker compose --env-file config/<target>/compose.env --env-file targets/<target>/compose/.env \
  -f targets/<target>/compose/compose.yaml \
  [-f targets/<target>/compose/compose.private.yaml] up -d --remove-orphans

# Check for updates (opens Renovate PRs on GitHub) — machine-local
bash scripts/renovate.sh
```

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
