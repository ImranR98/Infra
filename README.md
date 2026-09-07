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

## K3s node provisioning (Ansible)

Node provisioning uses the semi-official **k3s-io/k3s-ansible collection** ([`k3s.orchestration`](https://github.com/k3s-io/k3s-ansible), git-pinned in `ansible/requirements.yaml`): the collection owns the installer, `/etc/rancher/k3s/config.yaml`, and the systemd service. There is **no inventory file for provisioning**: `k3s_join.yaml` builds its node host at runtime via `add_host`, so any node can become the control plane and any node can join in any role. Cluster policy (SELinux, `write-kubeconfig-mode: "0640"`, `flannel-backend: wireguard-native`, sysctls, firewall ports, node labels, the containerd CDI drop-in, the kubectl group) lives in the playbooks + the `k3s_node_extra` role.

Prerequisites on the control host only (not on the nodes being provisioned): `ansible-playbook ansible/playbooks/prereqs.yaml` — bootstraps ansible-core via the package manager first — installs the required collections (`ansible.posix`, `community.general`, `k3s.orchestration`) and the `githubixx.ansible_role_wireguard` role, plus the validation tools (`ansible-lint`, `yamllint`). Manual alternative:

```bash
dnf install ansible-core
ansible-galaxy install -r ansible/requirements.yaml
```

Bootstrap a control plane — run **on** the node (the collection downloads the official `get.k3s.io` installer over TLS; the repo's node extras cover firewall, sysctls, CDI, kubectl group, labels):

```bash
ansible-playbook ansible/playbooks/k3s_server.yaml
```

Join a worker (run **on** the control plane; the token is read locally and passed to the joining node as an inventory variable — `no_log` at both ends, stored on the node in the root-only `k3s-agent.service.env`, the standard k3s agent pattern):

```bash
ansible-playbook ansible/playbooks/k3s_join.yaml -e node_ip=192.168.1.50 -e node_user=myuser -e k3s_role=agent
# or join another server: ... -e k3s_role=server
# AMD GPU: -e k3s_amdgpu_mode=auto (lspci-detected) | yes | no
# other flags: -e k3s_scheduling_discouraged=true, -e k3s_longhorn_replicas=true, --check, --diff
```

Update a node IP after a network change (run **on** srv0; retained bash):

```bash
sudo bash targets/srv0/update-node-ip.sh --ip 192.168.1.51
```

Validate the provisioning playbooks without touching any hosts: `ansible-playbook --syntax-check ansible/playbooks/*.yaml` + `yamllint -c ansible/.yamllint ansible` + `ansible-lint -c ansible/.ansible-lint --offline ansible`.

Dry-run on a test VM (Multipass): `multipass launch -n testnode fedora`, SSH in, copy the repo, run the prereqs playbook, then `ansible-playbook ansible/playbooks/k3s_server.yaml --check --diff` before the real run. Re-running it on an installed node is a no-op (the collection only re-runs the installer when the installed version is older than `k3s_version` (`stable`), so it can't fight system-upgrade-controller's version ownership).

## More

Detailed documentation lives in [AGENTS.md](AGENTS.md). Note that while LLMs are used in development, the LLM isn't the one putting its data on the line. [It is just a tool](https://www.normaltech.ai/p/ai-as-normal-technology) and is used like one.
