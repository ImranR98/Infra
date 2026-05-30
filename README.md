# Atlas

Infrastructure-as-code for self-hosted services. Deploy and manage Docker
Compose stacks and K3s Kubernetes clusters from a single codebase, with
automated updates and a security-first design.

## What it does

Atlas turns a directory of YAML configs and shell scripts into running
services on your machines. Each machine is a **target** &mdash; a directory
that declares what to run and how.

A single command provisions everything:

```bash
./atlas.sh <target> compose install     # Deploy as Docker Compose stack
./atlas.sh <target> k3s setup           # Bootstrap a K3s cluster
```

Services are configured with `$VARIABLE` placeholders. Secrets stay in
gitignored files. Templates render to systemd units or kubectl-applied
Kubernetes manifests.

## Highlights

- **Two paradigms, one tool.** Compose for simple stacks, K3s for full
  Kubernetes orchestrations &mdash; mix and match per machine.
- **Validate before you deploy.** Catches missing variables, YAML errors,
  and broken Kubernetes manifests before they hit production.
- **Automated updates.** Renovate scans for Docker image, Helm chart, and
  plugin updates across all YAML files. A Python script applies them,
  respecting version-pinning annotations.
- **Zero-trust networking.** Kubernetes NetworkPolicies default-deny all
  traffic, then allow only what each service needs. DNS, cluster-internal
  routing, and internet access for Helm installs are explicitly permitted.
- **SSO and intrusion prevention.** All web services go through Traefik with
  Authelia SSO/MFA, CrowdSec intrusion detection, and optional geo-blocking.
- **Cross-distro.** Auto-detects apt, dnf, or rpm-ostree (Fedora Atomic).
  Installs Docker, kubectl, and all prerequisites with one command.
- **Remote management.** Join K3s nodes over SSH, pull backups from remote
  machines, and update cluster networking after IP changes.

## Quick start

```bash
git clone <repo-url> /opt/atlas && cd /opt/atlas
cp targets/myhost/VARS.template.sh VARS.myhost.sh   # edit with real values
./atlas.sh myhost prereqs                            # install dependencies
./atlas.sh myhost validate                           # check everything
./atlas.sh myhost compose install                    # deploy
```

## Documentation

Detailed docs live in [`docs/`](docs/index.md), ordered for progressive reading:

| # | Topic |
|---|-------|
| 1 | [Project Overview](docs/01-overview.md) |
| 2 | [Getting Started](docs/02-getting-started.md) |
| 3 | [Architecture](docs/03-architecture.md) |
| 4 | [Targets](docs/04-targets.md) |
| 5 | [Commands Reference](docs/05-commands-reference.md) |
| 6 | [Compose Workflow](docs/06-compose-workflow.md) |
| 7 | [K3s Workflow](docs/07-k3s-workflow.md) |
| 8 | [Security Model](docs/08-security.md) |
| 9 | [Updates and Maintenance](docs/09-updates-and-maintenance.md) |
| 10 | [Standard vs Custom](docs/10-standard-vs-custom.md) |

## Requirements

Linux (Debian/Ubuntu, Fedora, Fedora Atomic). Root or sudo access. The
`prereqs` command installs Docker, yq, envsubst, jq, curl, and python3.
Renovate (npm) is needed for the update scanner.
