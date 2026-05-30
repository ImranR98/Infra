# 1 &mdash; Project Overview

## What is Atlas?

Atlas is an **Infrastructure-as-Code (IaC) management shell tool** that
orchestrates self-hosted services across multiple machines. It handles two
deployment paradigms from a single codebase:

- **Docker Compose** stacks &mdash; for simpler single-host deployments
- **K3s Kubernetes** clusters &mdash; for complex multi-service deployments

A single machine ("target") can use one or both paradigms. Atlas manages the
full lifecycle: provisioning prerequisites, rendering configuration templates,
deploying services, applying security policies, and scanning for updates.

## Design philosophy

1. **Everything as code.** All configuration lives in version-controlled YAML
   files and shell scripts. No manual steps needed for deployment.

2. **Templating via shell variables.** YAML files use `$VARIABLE_NAME`
   placeholders that are substituted at render time by `envsubst`. Secrets
   are kept in `VARS.<target>.sh` files (gitignored).

3. **Target abstraction.** Each physical or virtual machine is a "target"
   with its own configuration, secrets, and optionally custom commands. The
   target system is flexible &mdash; see [Targets](04-targets.md) for the full
   model.

4. **Validation before deployment.** The `validate` command checks YAML
   syntax, variable references, and Kubernetes manifests before anything
   touches production.

5. **Defense in depth.** Kubernetes NetworkPolicies default-deny all traffic,
   then selectively allow only what each service needs. All web traffic goes
   through Traefik with Authelia SSO/MFA and CrowdSec intrusion prevention.
   See [Security Model](08-security.md).

6. **Automated updates.** Renovate scans YAML files for Docker image tags,
   Helm chart versions, and Traefik plugin versions. A Python script applies
   discovered updates with preservation annotations. See
   [Updates and Maintenance](09-updates-and-maintenance.md).

## Repository layout

```
Atlas/
├── atlas.sh                    # Main entry point (source this or run it)
├── lib/                        # Core library
│   ├── common.sh               # Utilities: packages, vars, compose-gen, k3s, validation
│   └── dispatch.sh             # Command dispatcher / router
├── commands/                   # Shared command implementations
│   ├── prereqs.sh              # Install system prerequisites
│   ├── update.sh               # Scan/apply updates via Renovate
│   ├── _apply_updates.py       # Python helper: parse Renovate log, apply to YAML
│   ├── compose/                # Compose subcommands
│   └── k3s/                    # K3s subcommands
├── targets/                    # Target-specific configurations
│   └── <target-name>/
│       ├── compose/compose.yaml
│       ├── compose/templates/
│       ├── k3s/                # Optional: K3s components
│       │   └── groups.yaml
│       ├── commands/           # Optional: target-specific commands
│       └── VARS.template.sh
├── renovate.json               # Renovate configuration
├── .gitignore
├── current_target/             # Runtime-generated state (gitignored)
└── cache/                      # Renovate/containerbase cache (gitignored)
```

## Key concepts

- **Target**: A named deployment profile (corresponds to a machine).
  Targets are flexible: they can use Compose, K3s, or both. See
  [Targets](04-targets.md) for how they work.
- **VARS file**: `VARS.<target>.sh` in the repo root. Contains secrets and
  configuration values. Never committed to git.
- **Template**: `VARS.template.sh` inside each target directory. Documents
  required variables with placeholder values and generation instructions.
- **Component**: A K3s subdirectory with Kubernetes manifests. Each is a
  self-contained unit deployable via `k3s install`.
- **Group**: An ordered list of K3s components in `groups.yaml`. Deployed
  together via `k3s group`.
