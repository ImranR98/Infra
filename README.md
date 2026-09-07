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
# Install prerequisites (task, Docker, yq, jq, python3, python3-dotenv, go, ansible-core) — an Ansible playbook
# (no task installed yet? run the ansible-core bootstrap from the prereqs task manually)
task prereqs

# Create your variables file from the template (dotenv format)
cp targets/<target>/VARS.template.env secrets/VARS.<target>.env
# Edit secrets/VARS.<target>.env with your secrets and settings
# srv0 k3s: helm values live in secrets/values.srv0.yaml (keys documented in VARS.template.env)

# Validate your configuration
task <target>:validate

# Deploy
task <target>:compose:install
task <target>:k3s:group:base:apply
task <target>:k3s:group:apps:apply

# Check for updates (opens Renovate PRs on GitHub; no target needed)
task renovate
```

Commands that take arguments pass them after `--`, e.g. `task srv0:k3s:deploy -- base diff`.

## K3s node provisioning (Ansible)

Node provisioning is declarative Ansible ([`ops/ansible/`](ops/ansible/)) driven by one task. There is **no inventory file anywhere**: the wrapper builds a throwaway inventory in `/tmp` from CLI arguments, so any node can become the control plane and any node can join in any role at runtime. Cluster policy defaults (SELinux, `write-kubeconfig-mode: "0640"`, `flannel-backend: wireguard-native`, sysctls, firewall ports, node labels) live in the roles' `defaults/main.yml`.

Prerequisites on the control host only (not on the nodes being provisioned): `task prereqs` — itself an Ansible playbook, it bootstraps ansible-core via the package manager first — installs the required collections (`ansible.posix`, `community.general`) and the validation tools (`ansible-lint`, `yamllint`). Manual alternative:

```bash
dnf install ansible-core
ansible-galaxy collection install -r ops/ansible/requirements.yml
```

Bootstrap a control plane — run **on** the node (it downloads the official `get.k3s.io` installer, verifies its SHA256 against GitHub's `main` install.sh — fail-closed, overridable with `k3s_installer_sha256` — writes config drop-ins, firewall, sysctls, kubectl group, labels):

```bash
task srv0:k3s:provision
```

Join a worker (run **on** the control plane; the token is read locally and passed to the installer via environment only — never argv, disk, or logs):

```bash
task srv0:k3s:provision -- 192.168.1.50 myuser agent --amdgpu auto --longhorn
# or join another server: ... server
# AMD GPU: --amdgpu auto (lspci-detected) | yes | no
# other flags: --scheduling-discouraged, --longhorn, --check, --diff, -e key=value
```

Update a node IP after a network change (run **on** the node; retained bash implementation behind an Ansible wrapper):

```bash
task srv0:k3s:update-node-ip -- --ip 192.168.1.51
```

Validate the provisioning playbooks without touching any hosts:

```bash
task srv0:k3s:validate    # syntax-check + yamllint + ansible-lint
```

Dry-run on a test VM (Multipass): `multipass launch -n testnode fedora`, SSH in, copy the repo, run `task prereqs`, then `task srv0:k3s:provision -- --check --diff` before the real run. Re-running `provision` on an installed node is a no-op (it never re-runs the installer, so it can't fight system-upgrade-controller's version ownership).

## Migrating from the old `./infra.sh` CLI

`./infra.sh` (and the bash dispatcher behind it) was replaced by `task` + a Python VARS validator (`lib/vars_validator.py`), with environment loading folded into `lib/common.sh`, and the VARS files moved from bash exports (`VARS.*.sh`) to dotenv (`VARS.*.env`, converted on each machine by a one-time script that has since been deleted). Command mapping is 1:1 — `./infra.sh srv0 compose install` became `task srv0:compose:install`. The old bash K3s provisioning (`k3s:setup` / `k3s:join`) was later replaced by the single Ansible task `k3s:provision` described above.

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
