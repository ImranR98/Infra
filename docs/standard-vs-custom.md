# Standard vs. Custom

Infra sits in an interesting space on the homelab automation spectrum. It uses well-known open-source tools in their intended ways, but wraps them in a custom orchestration layer. This document separates what is "standard" from what is "custom" in this repo.

## Standard: tools used as intended

### Docker and Docker Compose

Docker and Docker Compose are used exactly as documented — `docker compose up -d`, `docker compose down`, standard `compose.yaml` format with no extensions. Infra renders templates and starts the stack directly. Reboot survival comes from Docker's native `restart: unless-stopped` policies, not a systemd wrapper. Any Docker user could look at the rendered `compose.yaml` and understand it immediately.

### K3s

K3s is installed via the official installer script, configured through standard `/etc/rancher/k3s/config.yaml.d/` drop-ins, and managed with `kubectl`. Node labels, SELinux integration, and firewall rules are all standard K3s features.

### kubectl kustomize

Kustomize is used as the native Kubernetes configuration tool. Each component has a standard `kustomization.yaml` with `resources:`, and `kubectl kustomize` builds the final manifests. No custom kustomize plugins or generators.

### Renovate

Renovate runs in its standard local mode with a standard `renovate.json` config file. The `customManagers` are regex-based, which is Renovate's documented extensibility mechanism. The `packageRules` for pinning digests use standard Renovate features.

### envsubst

`envsubst` from GNU gettext is used in its standard form — pass a list of variable names, it replaces them in text. No custom wrappers or modified behavior.

### WireGuard

WireGuard uses `wg-quick`, standard `wg0.conf` syntax, and standard systemd integration. The split-tunnel routing (`0.0.0.0/1, 128.0.0.0/1`) is a well-known WireGuard technique for selective routing.

### cert-manager, Traefik, Authelia, CrowdSec

All Kubernetes applications are deployed via standard CRDs, HelmCharts, and standard configurations. Their documentation applies directly.

### systemd

WireGuard tunnels run as standard `wg-quick@wg0` systemd units with a restart drop-in. The Docker daemon, K3s, and other host services are managed by their standard systemd units. Compose stacks are not wrapped in systemd — they rely on Docker's native restart policies.

## Custom: Infra-specific glue

### The dispatch system

The command routing in `lib/dispatch.sh` is custom. It walks directory trees to resolve subcommands, checks target-specific overrides before falling back to global scripts, and supports both bash and python3. There's no off-the-shelf framework used here — it's a bespoke shell-script dispatcher designed for this repo.

### Target abstraction

The concept of "targets" as directory-based configuration units with overridable commands is custom. While similar to Ansible's inventory or NixOS's configurations, the implementation is from scratch — each target is a directory, and the dispatch router and variable resolution logic tie everything together.

### The Authelia header gate

The first-run protection is a custom Traefik WASM plugin (`authelia-header-gate`,
built with TinyGo and loaded via `--experimental.localplugins`) plus an automatic
variable (`AUTHELIA_HEADER_GATE_ENABLED`) that is set to `"true"` only when a
first deploy is detected (missing Authelia sentinel/config on the target). It
blocks requests without an Authelia session during bootstrap, then passes
everything once the VARS value (`"false"`) wins. This replaces a manual
two-phase deployment pattern.

### `.secret` and `.plain` file conventions

The file extension-based rendering behavior (`.secret` → envsubst + chmod 600, `.plain` → copy verbatim) is a custom convention built on top of envsubst. Standard envsubst doesn't have file-extension-sensitive behavior.

### The two-tier variable system

The split between `VARS.template.sh` (documentation + validation source) and `VARS.<target>.sh` in `secrets/` (actual secrets) is custom. The validation that cross-references template exports with actual file content is custom logic in `lib/common.sh`.

### Compose template rendering pipeline

`configure_compose_templates()` is custom — it walks the templates directory, classifies files by extension (`.secret`, `.plain`, or plain envsubst), and runs each component's `prep.sh` hook before rendering. This is a bespoke rendering pipeline.

### The `post.sh` CRD waiter

`wait_for_crds()` is a custom shell function that polls `kubectl wait` for CRD establishment. While it uses standard kubectl, the wrapper function with timeout and retry logic is Infra-specific.

### backup-state remote mode

The remote backup system (SSH into a remote Infra instance, stream tar back over the connection) is a custom shell script workflow. The `INFRA_BACKUP_STREAM` mode switch is custom.

### Multi-distro package management

The `detect_pkgmgr()` / `install_pkgs()` / `ensure_docker_repo()` functions handle apt, dnf, and rpm-ostree (immutable Fedora like secureblue) uniformly. While the individual commands are standard, the detection and dispatch layer is custom.

### The Renovate-to-source update pipeline

`_apply_updates.py` is a custom Python script that parses Renovate's debug output, finds version changes, and applies them to source YAML files. Renovate's normal mode is to open PRs; applying changes directly to source files is a custom workflow built for this repo's single-developer, local-only model.

### Traefik plugin updater

The plugin version checker in `update.sh` that queries the GitHub Releases API and replaces version strings in YAML files is custom. It handles plugins that Renovate can't scan (because they're in `additionalArguments` strings, not structured YAML).

### mTLS certificate generation

The `generate-mtls-certs` command generates per-pair CA and X.509 certificates for mTLS authentication between any client and server. It supports preboot-specific client certificates (used by the FRP preboot integration), and outputs copy-paste blocks for VARS files.

### Preboot FRPC + dracut-crypt-ssh

The initramfs integration for remote LUKS unlock is customized for Infra's FRP infrastructure. While `dracut-crypt-ssh` is an existing project, the FRPC preboot integration and the `check_root_luks.sh` detection logic (a `lib/` helper, not a CLI command) are custom. `bigpc` uses a crypt-ssh-only variant that patches the dropbear port to 8887 for direct LAN unlock instead of tunneling through FRP.

### WireGuard routing customizations

The `AllowedIPs` rewrite and endpoint dead-loop fix in `wireguard.sh` are specific to the repo's networking setup (K3s subnets that must bypass VPN). While the routing techniques are standard, the automated detection and configuration of them is custom.

## What this means for users

- **If you know Docker, Kubernetes, and WireGuard**, you'll understand the deployed services immediately. Infra does not invent new abstractions for these — it uses them in standard, documented ways.
- **If you want to understand how Infra orchestrates these tools**, you'll need to learn the custom dispatch system, the templating conventions, and the bootstrap patterns. These are not standard tools — they're the glue unique to this repo.
- **If you want to port Infra to a standard tool**, the custom glue maps roughly to: the dispatch system (like Task or Make), the variable model (like Ansible vault or SOPS), the component lifecycle (like Helm hooks or ArgoCD sync waves). But Infra is intentionally kept simple — bash scripts and envsubst — to remain understandable and maintainable by one person.
