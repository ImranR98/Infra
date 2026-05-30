# 4 &mdash; Targets

## What is a target?

A **target** represents a physical or virtual machine that Atlas manages.
Each target is a directory under `targets/` containing:

- A `compose/` directory with `compose.yaml` and optionally `templates/` and custom scripts
- Optionally a `k3s/` directory with component subdirectories and `groups.yaml`
- Optionally a `commands/` directory for target-specific command overrides
- A `VARS.template.sh` that documents required variables

The target system is flexible: a target can use only Compose, only K3s, or
both. The presence of the `compose/` or `k3s/` directory determines which
deployment paradigm applies.

## Target anatomy

```
targets/<name>/
├── VARS.template.sh            # Template of required environment variables
├── compose/                    # Docker Compose configuration
│   ├── compose.yaml            # Main compose file (envsubst-processed)
│   └── templates/              # Config files for services
│       └── <service>/
│           ├── config.secret   # envsubst-processed, chmod 600
│           └── data.plain      # Copied as-is
├── k3s/                        # K3s Kubernetes configuration (optional)
│   ├── groups.yaml             # Ordered groups for deployment
│   └── <component>/            # Individual K3s component directories
│       ├── kustomization.yaml  # Kustomize resource list
│       ├── *.yaml              # Kubernetes manifests (envsubst-processed)
│       ├── prep.sh             # Pre-deploy hook (optional)
│       ├── post.sh             # Post-deploy hook (optional)
│       └── delete.sh           # Custom teardown logic (optional)
└── commands/                   # Target-specific command overrides (optional)
    ├── compose/                # Override shared compose commands
    └── k3s/                    # Override shared k3s commands
```

## Target types

Targets in the repository fall into three categories:

### Compose-only targets

Targets with only a `compose/` directory. These deploy services as Docker
containers managed by systemd. The compose file uses `$VARIABLE_NAME`
placeholders throughout.

Typical use case: a machine that runs a handful of containerized services
without needing Kubernetes orchestration.

### K3s + Compose targets

Targets with both `compose/` and `k3s/` directories. The compose layer
typically handles "infrastructure" services (e.g., FRP tunneling) while
the K3s layer runs the full application stack.

These targets may also have preboot support &mdash; custom scripts in the
`compose/` directory that handle initramfs-level configuration (e.g., LUKS
disk encryption with remote SSH unlock).

### Targets with custom commands

Targets can contain a `commands/` directory that overrides or extends
shared commands. The dispatcher checks `targets/<TARGET>/commands/`
before `commands/`, so a target can completely replace or extend any
command.

This is used for workflows that only apply to a specific machine (e.g.,
preboot setup, hardware-specific configuration).

## Variable templates

Each target has a `VARS.template.sh` that declares required variables using
`export VARNAME="placeholder"`. The template serves as both documentation
and validation: before any command runs, `source_env()` verifies that every
`export` from the template exists in the actual VARS file.

### Variable categories

Variables typically fall into these categories:

| Category | Purpose | Example |
|----------|---------|---------|
| Domain | Service domain name and contact email | `SERVICES_DOMAIN`, `DOMAIN_OWNER_EMAIL` |
| Infrastructure | FRP tunneling, network paths | `PROXY_HOST`, `FRPC_TOKEN` |
| Authentication | SSO, MFA, passwords | `AUTHELIA_JWT_SECRET`, `AUTHELIA_USERS_DATABASE` |
| Service-specific | Per-app configuration | Database passwords, API keys |
| Host paths | Filesystem paths for volumes | `MAIN_PARENT_DIR`, `MEDIA_DIR_PATH` |
| Multi-line | Embedded YAML/config strings | GeoBlock config, Authelia user database |

### Multi-line variables

Some variables contain multi-line values (e.g., Authelia users database,
GeoBlock configuration). These use shell string syntax:

```bash
export AUTHELIA_USERS_DATABASE="users:
  admin:
    disabled: false
    displayname: \"Admin\"
    password: \"...\""
```

Multi-line variables rely on indentation being preserved through envsubst.

### Generating secrets

The template comments provide commands for generating secure random values:

```bash
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me"  # openssl rand -hex 32
export AUTHELIA_REDIS_PASSWORD="change_me"         # openssl rand -base64 32
export AUTHELIA_JWKS_KEY="...change_me..."         # openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 ...
```

## K3s component model

When a target includes a `k3s/` directory, it contains:

### groups.yaml

Defines ordered groups of components for batch deployment:

```yaml
base:
  - namespaces
  - nfs-server
  - cert-manager
  # ...
apps:
  - immich
  - jellyfin
  # ...
```

Base components are infrastructure (storage, networking, security). App
components are user-facing services. The "base" group must be deployed
before "apps". When deleting, apps are deleted before base (and base
deletion is blocked if Bound PVCs exist).

### Component directories

Each component is a subdirectory with:

| File | Required | Purpose |
|------|----------|---------|
| `kustomization.yaml` | Yes | Declares which YAML files to include |
| `*.yaml` | Usually | Kubernetes resources (Deployments, Services, IngressRoutes, etc.) |
| `helmchart.yaml` | Sometimes | For Helm-deployed components using K3s's built-in Helm controller |
| `prereqs.yaml` | Sometimes | Resources that must exist before the main deployment |
| `ingress.yaml` | Sometimes | Traefik IngressRoute definitions |
| `network-policy.yaml` | Sometimes | Component-specific NetworkPolicy rules |
| `prep.sh` | No | Pre-deploy hook |
| `post.sh` | No | Post-deploy hook |
| `delete.sh` | No | Custom teardown logic |

See [K3s Workflow](07-k3s-workflow.md) for the full component deployment
pipeline.

## Compose templates

Files under `compose/templates/` are processed with rules based on their
naming:

### Naming conventions

| Suffix | Behavior |
|--------|----------|
| `.secret` | envsubst-processed, then `chmod 600` |
| `.plain` | Copied directly without substitution |

Any other file is envsubst-processed without permission changes.

### Special: Authelia handling

Files under `templates/authelia/` receive special first-run behavior. Lines
ending with `# IGNORE INITIALLY` are commented out on the first run, then
processed normally on subsequent runs. This allows deploying configuration
that would fail validation before certain prerequisites exist.

The Authelia users database is written from the `AUTHELIA_USERS_DATABASE`
variable directly to the state directory.

### Special: Traefik ACME

When processing `traefik/*` files, an empty `acme.json` file (`{}` with mode
600) is created if it doesn't already exist, since Traefik requires this file
to start.

## Preboot support

Some targets include custom scripts in their `compose/` directory for
pre-boot (initramfs) configuration. This is used for machines with
LUKS-encrypted root disks.

A target with preboot support typically includes:

- **`check_root_luks.sh`**: Detects whether the root filesystem is on a LUKS
  device by checking `lsblk` for `crypt` entries.
- **`dracut-crypt-ssh.install.sh`**: Installs and configures
  `dracut-crypt-ssh` (Dropbear SSH in initramfs) to allow remote SSH-based
  LUKS unlock before the root filesystem is mounted. Handles both dnf and
  rpm-ostree systems.
- **`frpc-preboot.install.sh`**: Clones the `dracut-frpc` repo and runs its
  setup script to embed an FRP client into the initramfs, tunneling SSH
  through the FRP server before root is mounted.

The target-specific command `compose/install-preboot.sh` orchestrates the
full preboot setup: checks for LUKS, installs dracut-crypt-ssh, installs
the preboot FRP client, and rebuilds the initramfs.

## Target-specific commands

Targets can override any shared command by placing a script with the same
path under `targets/<TARGET>/commands/`. The dispatcher checks this
directory before the shared `commands/` directory.

This allows:
- Adding commands that only make sense for a specific target (e.g., preboot
  setup, hardware configuration)
- Replacing shared commands with target-specific implementations
- Extending shared commands for target-specific behavior

## Adding a new target

1. Create the target directory:
   ```bash
   mkdir -p targets/myhost/compose/templates
   ```

2. Create `VARS.template.sh` with required variables.

3. Create `targets/myhost/compose/compose.yaml`.

4. Optionally add K3s components under `targets/myhost/k3s/`.

5. Create `VARS.myhost.sh` at the repo root with real values.

6. Validate:
   ```bash
   ./atlas.sh myhost validate
   ```

7. Deploy:
   ```bash
   ./atlas.sh myhost compose install
   ```
   Or bootstrap K3s and deploy:
   ```bash
   ./atlas.sh myhost k3s setup
   ./atlas.sh myhost k3s group base initial
   ./atlas.sh myhost k3s group apps initial
   ```
