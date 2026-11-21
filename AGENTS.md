# AGENTS.md

Infra is the infrastructure-as-code repo for a multi-machine homelab. Everything a
target needs lives in `targets/<t>/`; shared logic sits in `scripts/`; secrets live in
the gitignored `config/`. There is no build step. `docs/` is the handbook; this file is
the rulebook.

Targets, request paths, and design goals: `docs/architecture.md`.

## Read first

- `docs/architecture.md` — targets and request paths
- `docs/platform.md` — K3s, storage, hardware, multi-node
- `docs/operations.md` — deploy, updates, backups, maintenance
- `docs/configuration.md` — config, secrets, host facts
- `docs/decisions.md` — invariants and tradeoffs

## Hard rules

- **Provision nodes only via `scripts/k3s-server.sh`/`k3s-join.sh`** — no raw
  installers or ad-hoc joins. See `docs/platform.md`.
- **Get kubeconfig access through `scripts/kubeconfig-unlock.sh`** — the admin
  kubeconfig stays root-only (0600). Never restore group/world access or a permanent
  `KUBECONFIG`.
- **Leave `~/infra_state/` alone** — it holds `compose_live_state/` and
  `k3s_live_state/`.
- **Keep secrets out of git** — `config/`, `compose.private.yaml`, and
  `targets/*/compose/.env` are ignored. See `docs/configuration.md`.
- **New components need NetworkPolicies and `infra.resources` tiers** — raw
  `memory:`/`cpu:` keys are rejected by `validate.sh`.
- **Storage**: `nfs-apps` is the default RWX class, `local-apps` is the RWO local
  twin, and the static `hostpath` PV/PVCs pin the Main tree. Don't add other dynamic
  PVs or raw hostPath app data. See `docs/platform.md#storage`.
- **Hardware**: use `infra.local/amd-igpu`, `infra.local/vaapi`, or
  `infra.local/conbee`; workloads are fixed to the current AMD/VAAPI/ConBee board.
  The generic device plugin also advertises Intel/dGPU resources, but no chart uses
  them. See `docs/platform.md#hardware`.
- **Renovate**: app repos extend `renovate-preset.json`; non-major app PRs auto-merge
  after `test`, majors wait on the Dependency Dashboard. Infra PRs are never
  auto-merged. Never hand-pin an app digest. See `docs/operations.md#updates`.
- **Helm**: only project-maintained charts; Home Assistant is the single third-party
  exception. Pin app-version-sensitive chart images so Renovate tracks the app. See
  `docs/platform.md#helm`.
- **D4TA is one suite, one host** — `data.<SERVICES_DOMAIN>` carries the dashboard and
  modules. Don't reintroduce per-app hosts/deployment names. See
  `docs/apps.md#d4ta-multi-module-suite`.
- **TLS** — `edge-public-tls` (SANs from `PUBLIC_HOSTS`) and `edge-private-tls`
  (`PRIVATE_HOSTS`, websecure only). No per-app certs or wildcards. See
  `docs/public-edge.md`.
- **Authelia access control is dual-source** — structural bypasses/catch-all stay in
  the charts; group/user rules live in `config/`. Don't add personal group names to
  the chart. See `docs/public-edge.md#authentication-and-access-control`.
- **Keep the public-exposure MTU watcher and VPN connection notifications** unless a
  replacement is measured and documented. See `docs/tunnels.md`.

## Resource sizing

Every container picks a tier from `infra.resources` (shared by both charts through
the `k3s-common` library chart). Raw `memory:`/`cpu:` keys are rejected. The tier
table, derivation, deviations (`memLimit`, `cpu`, `custom`), and CPU-limit rules are
in `docs/platform.md#resource-sizing`.

## Common commands

```bash
bash scripts/validate.sh <target>
bash scripts/kubeconfig-unlock.sh
bash scripts/renovate.sh [apps|infra|all|clear-cache] [--dry-run]
```

Deploy commands: `docs/operations.md#deploy`. Backups/restore:
`docs/operations.md#backups`. Script index: `docs/operations.md#scripts`.
All docs: `docs/README.md`.
