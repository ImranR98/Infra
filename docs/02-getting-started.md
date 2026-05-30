# 2 &mdash; Getting Started

## Prerequisites

### System requirements

- Linux (Debian/Ubuntu, Fedora, or Fedora Atomic/SecureBlue)
- Root or sudo/run0 access
- Internet access for installing packages and pulling containers

### Required tools (auto-installed by `prereqs`)

The `prereqs` command installs everything needed:

| Tool | Purpose |
|------|---------|
| Docker + Docker Compose plugin | Container runtime and orchestration |
| yq | YAML processing (validation, parsing) |
| envsubst | Variable substitution in templates |
| jq | JSON processing |
| curl | Downloads |
| python3 | Update script (`_apply_updates.py`) |

### Additional requirements by paradigm

| Paradigm | Extra tools |
|----------|-------------|
| K3s | kubectl, ssh, rsync (for remote nodes) |
| Updates | renovate (npm) or npx |

## Installation

Clone the repository:

```bash
git clone <repo-url> /opt/atlas
cd /opt/atlas
```

Make the entry point executable:

```bash
chmod +x atlas.sh
```

Install system prerequisites:

```bash
./atlas.sh <target> prereqs
```

This command auto-detects your Linux distribution and package manager (apt,
dnf, or rpm-ostree) and installs Docker, Docker Compose, yq, envsubst, jq,
curl, and python3.

## Configuring a target

### Step 1: Create the target directory

Look at existing targets under `targets/` for examples, or create a new
directory:

```bash
mkdir -p targets/myhost/compose/templates
```

### Step 2: Create the VARS template

A VARS template documents every variable the target needs. Every variable
must be exported:

```bash
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"
```

The comments serve as documentation, often including commands to generate
secure random values:

```bash
export SOME_SECRET="change_me"  # openssl rand -hex 32
```

Atlas validates that every variable declared in the template exists in the
actual VARS file before running any command.

### Step 3: Create the actual VARS file

Create `VARS.myhost.sh` at the repository root with real values:

```bash
cp targets/myhost/VARS.template.sh VARS.myhost.sh
# Edit VARS.myhost.sh with real secrets and config
chmod 600 VARS.myhost.sh
```

VARS files are gitignored by the pattern `/VARS.*.sh` in `.gitignore`.
Atlas falls back to `VARS.sh` if a target-specific file is not found.

### Step 4: Validate

```bash
./atlas.sh myhost validate
```

This checks:
- YAML syntax of all compose and k3s files
- Variable references against the VARS template
- `kubectl kustomize` build for each K3s component
- `docker compose config` dry run for compose files

## Writing a compose.yaml

Create `targets/myhost/compose/compose.yaml` using Docker Compose syntax.
Use `$VARIABLE_NAME` for values that come from the VARS file:

```yaml
services:
  myapp:
    image: myimage:latest
    container_name: myapp
    restart: always
    volumes:
      - $COMPOSE_STATE_DIR/myapp/config:/config:ro
    environment:
      - DOMAIN=$SERVICES_DOMAIN
```

## Adding K3s components

See [K3s Workflow](07-k3s-workflow.md) for the full component model and
deployment pipeline.

## Running commands

The general syntax is:

```bash
./atlas.sh <target> <command> [subcommand...] [args...]
```

Examples:

```bash
./atlas.sh myhost validate         # Validate configuration
./atlas.sh myhost prereqs          # Install prerequisites
./atlas.sh myhost compose install  # Deploy compose stack
./atlas.sh myhost list-domains     # List all domains in use
```

If you omit the command, the tool prints available commands for that target.

## First deployment

A full deployment sequence for a target that uses both Compose and K3s:

```bash
# 1. Validate everything
./atlas.sh myhost validate

# 2. Install dependencies on the machine
./atlas.sh myhost prereqs

# 3. Bootstrap K3s (auto-elevates to root)
./atlas.sh myhost k3s setup

# 4. Deploy base infrastructure components
./atlas.sh myhost k3s group base initial

# 5. Deploy application components
./atlas.sh myhost k3s group apps initial
```

For a compose-only target:

```bash
./atlas.sh myhost prereqs
./atlas.sh myhost compose install   # Renders, creates systemd unit, starts
```

See [Targets](04-targets.md) for details on the targets included in the
repository.
