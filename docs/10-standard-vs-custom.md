# 10 &mdash; Standard vs Custom

This document categorizes the design decisions in Atlas: what follows common
open-source conventions and what is purpose-built for this project.

## Standard: Conventional tools and patterns

### Package management

- Uses standard Linux package managers (`apt`, `dnf`, `rpm-ostree`) with
  their idiomatic commands.
- Docker CE repository setup follows the official Docker documentation for
  each distro.
- Systemd unit files follow the standard `[Unit]`, `[Service]`, `[Install]`
  format.

### Docker and Compose

- Docker Compose files use standard v3/v4 syntax with YAML anchors (`&`, `*`)
  for reusable blocks (logging configuration).
- Container volumes, restart policies, healthchecks, and logging follow
  Docker Compose best practices.
- The systemd service wrapper around `docker compose up/down` is a standard
  pattern for managing Compose stacks as system services.

### Kubernetes

- **Kustomize**: All K3s components use standard `kustomization.yaml` files
  with the `kustomize.config.k8s.io/v1beta1` API.
- **HelmChart CRD**: Uses K3s's built-in `helm.cattle.io/v1` HelmChart
  custom resource, which is the standard way to deploy Helm charts on K3s.
- **NetworkPolicy**: Uses standard `networking.k8s.io/v1` NetworkPolicy
  resources with standard selectors, CIDR blocks, and port specifications.
- **Pod Security Standards**: Uses standard Kubernetes `pod-security`
  labels.
- **Traefik CRDs**: Uses standard `traefik.io/v1alpha1` IngressRoute and
  Middleware resources.
- **cert-manager**: Uses standard `cert-manager.io/v1` Issuer and
  Certificate resources.

### Infrastructure tools

- **Renovate**: Uses the standard Renovate CLI with a standard
  `renovate.json` configuration file. The regex managers, datasource
  templates (`docker`, `helm`), and versioning templates (`docker`,
  `semver`) are all standard Renovate features.
- **yq**: Used for YAML parsing and validation, following its standard CLI
  syntax (evaluate, extract, pipe).
- **envsubst**: Standard gettext utility for variable substitution.
- **jq**: Standard JSON processor.
- **rsync** and **ssh**: Standard tools for remote file sync and execution.

### Shell scripting

- **Strict mode**: Every script uses `set -euo pipefail`, which is the
  widely-recommended bash strict mode.
- **ShellCheck-compatible patterns**: Variables are quoted, arrays are used
  properly, and temporary files use `mktemp` with trap cleanup.
- **Library sourcing guard**: `lib/common.sh` uses `ATLAS_LIB_LOADED` to
  prevent double-sourcing, a standard pattern.
- **Help output**: Commands use `# DESC:` comments extracted by `sed`, a
  common self-documenting shell pattern.

### Git

- Standard `.gitignore` for build artifacts, cached data, secrets, and
  editor temp files.
- Secrets excluded via wildcard pattern (`/VARS.*.sh`).

## Standard: Design patterns and methodologies

### Infrastructure as Code

- All configuration is declarative (YAML) and version-controlled.
- Deployment is idempotent: running commands multiple times produces the
  same result.
- Secrets are externalized from configuration and never committed.

### Defense in depth

- Default-deny network policies are a standard Kubernetes security best
  practice.
- Namespace segmentation with Pod Security Standards follows the principle
  of least privilege.
- TLS everywhere (Let's Encrypt + cert-manager) is standard modern practice.
- SSO/MFA via Authelia follows the standard OIDC/ForwardAuth pattern for
  protecting web services.

### Templating

- Variable substitution with envsubst is a standard Unix approach for
  configuration templating.
- The VARS template + VARS file split (documentation vs actual values) is
  analogous to `.env.example` + `.env` patterns.

### Dependency management

- Renovate as a dependency update tool is one of the most popular choices
  alongside Dependabot.
- Digest pinning for floating tags is a standard Renovate feature.

## Custom: Purpose-built for Atlas

### Command dispatch system

**What it is**: A recursive, multi-directory command router that resolves
commands from both shared and target-specific directories, supports nested
subcommands, and handles both bash and Python runners.

**Why it's custom**: Most CLI tools use a library like Cobra (Go), Click
(Python), or getopts (bash). Atlas's dispatcher is built entirely from
scratch in pure bash, with a custom directory-walking resolution algorithm.
It treats filesystem directories as subcommand namespaces, making it easy
to add commands by dropping a `.sh` or `.py` file in the right place &
mdash; no registration step needed.

**Where**: `lib/dispatch.sh`

### YAML update engine

**What it is**: A Python script (`commands/_apply_updates.py`) that parses
Renovate's JSON debug output and applies version updates to YAML source files.

**Why it's custom**: Renovate typically creates PRs or update branches, but
Atlas works directly on a local filesystem with no git-forge integration.
The script implements local, in-place updates with preservation annotations
(`# PRESERVE_FULL`, `# PRESERVE_MAJOR`) that Renovate doesn't natively
support for custom regex managers.

### Template processing conventions

**What it is**: The `.secret` / `.plain` file naming convention that
controls envsubst processing and permission setting. Combined with special
handling for `authelia/*` and `traefik/*` template directories.

**Why it's custom**: This is a domain-specific convention invented for this
project. Most tools use explicit template configuration (e.g., Ansible's
`template` module with `mode`), but Atlas derives behavior from filename
suffixes and directory paths, which is a custom convention.

### `# IGNORE INITIALLY` annotation system

**What it is**: A mechanism where lines in Kubernetes YAML files ending with
`# IGNORE INITIALLY` are stripped during `initial` mode deployment and
included during normal `apply` mode.

**Why it's custom**: Kubernetes and Kustomize have no native concept of
"skip this resource on first deploy." Helm has `--skip-crds`, but Atlas
needs a finer-grained solution that works across both raw YAML and
HelmCharts. The comment-based annotation with a two-phase deploy (initial
then normal) is entirely custom.

### Longhorn deletion workaround

**What it is**: A custom `delete.sh` script that handles the circular
dependency between Longhorn's admission webhooks and CRD finalizers during
uninstall.

**Why it's custom**: This is a known limitation of Longhorn's Helm chart
where `helm uninstall --wait` hangs because the webhook service disappears
before CRD resources can be cleaned up. The script scales down controllers,
strips finalizers, and removes webhooks manually &mdash; a workaround
specific to this deployment.

### LUKS preboot integration

**What it is**: Custom scripts that embed an FRP client into the initramfs
so that SSH is available for remote LUKS unlock before the root filesystem
is mounted.

**Why it's custom**: While `dracut-crypt-ssh` is an existing tool, the
integration of FRP (fast reverse proxy) tunneling with dracut for pre-boot
connectivity is a custom combination. The scripts orchestrate multiple
tools (dracut-crypt-ssh, dracut-frpc, RPM-ostree kargs) in a way that's
specific to this infrastructure setup.

### Network policy: API server host IP workaround

**What it is**: The `base-policies.yaml` includes the API server's host
subnet (auto-detected as `$K8S_API_SERVER_SUBNET`) in egress rules.

**Why it's custom**: This is a workaround for kube-proxy's DNAT behavior on
K3s: traffic to the API server's ClusterIP gets rewritten to the node's
physical IP *before* NetworkPolicy evaluation, so the service CIDR rule
alone is insufficient. The auto-detection via kubectl endpoints and the
envsubst-based injection into NetworkPolicy YAML is custom infrastructure
glue.

### FRP version synchronization

**What it is**: The `compose build-frps` command that reads the FRPC version
from one target, builds a matching custom FRPS Docker image, pushes it to a
registry, and updates the FRPS target's compose file.

**Why it's custom**: This addresses a tight coupling between the FRP client
and server versions (they must match). The automated build-and-update
pipeline with cross-target version detection is specific to this project.

### Compose state backup via Docker tar container

**What it is**: The backup mechanism runs a temporary Alpine container that
mounts the state directory read-only and streams a tar archive, using
`--log-driver none` to prevent Docker from writing the tar stream to its
own json-file logs.

**Why it's custom**: Most backup solutions use host-level tar or a dedicated
backup tool. Running tar inside a throwaway container with specific Docker
flags to work around log driver behavior is an unusual but effective
approach for a containerized environment.

### Systemd unit generation

**What it is**: The `compose install` command dynamically generates a
systemd unit file with `docker compose up/down` as ExecStart/ExecStop and
`Restart=always`, then installs it via `systemctl`.

**Why it's custom**: While using systemd to manage Docker Compose is a known
pattern, the inline generation of the unit file based on target metadata
(rather than using a pre-written template or Docker's built-in restart
policies) is a custom approach that ties service management to the target
system.

### Multi-distro package installation

**What it is**: The `detect_pkgmgr()`, `install_pkgs()`, and
`ensure_docker_repo()` functions that abstract over apt, dnf, and
rpm-ostree.

**Why it's custom**: Most tools use Ansible or similar for cross-distro
management. Atlas implements this directly in bash, including distro-
specific Docker repository setup (apt keyrings, dnf config-manager). The
`rpm-ostree` support for immutable Fedora variants is particularly
unusual in shell-based tools.
