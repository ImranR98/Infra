# Risk assessment

## Change magnitude

| Magnitude | Examples | Baseline |
|---|---|---|
| Digest/pin refresh | floating `latest@sha256:` bumps, grouped `docker-digests` PR | Tier A (standard/elevated), Tier B (critical) |
| Patch | `1.2.3` → `1.2.4` | Tier A/B |
| Minor | `1.2.0` → `1.3.0` | Tier B (critical components: C) |
| 0.x minor | `0.5.3` → `0.6.0` | Tier B/C — 0.x minors may break; read the changelog |
| Major | `2.x` → `3.x` | Tier C |
| Kubernetes minor | k3s Plan `1.36` → `1.37` | Tier C |
| Helm chart version | HelmChart CR `version:` bumps, vendored charts | Tier B/C — check upstream values changes |

## Component criticality

**Critical** — breakage can cut off access, auth, storage, or the cluster:
k3s and its system-upgrade Plans, Traefik/Gateway/CRDs, Authelia (srv0 and vps0),
cert-manager, Longhorn, NFS server / csi-driver-nfs / host-volumes, public-exposure tunnel (WireGuard),
CrowdSec, coredns, and DB engines (authelia DB, immich-postgres, clickhouse, nextcloud DB).

**Elevated** — user-facing apps with data or auth; recoverable but disruptive:
immich, nextcloud, jellyfin, homeassistant, frigate, mosquitto, grafana, open-webui,
headlamp, navidrome, linkwarden, freshrss, opencanary.

**Standard** — self-contained tools with small blast radius:
dozzle, metube, uptime-kuma, plausible, shlink, owncast, isbn-lookup, pixelntfy,
logtfy, opodsync, syncthing, socket proxies, tech-sale/home-sale, strelaysrv.

**App repos** — the first-party apps in `APP_REPOS` (PixelNtfy, ISBN-Lookup,
our-times, order-manager, moving-sale-2027, Logtfy, opencode-sandbox, DSCPLN,
dscpln-config). Treat user-facing apps with data/auth as elevated; small tools as
standard. Their image publish is part of the change, so a green required check
(usually `test`) plus a non-pending `renovate/stability-days` is the merge gate,
and a successful `publish` is the pin/rollout gate.

## Tier rules

- **Tier A** — merge autonomously: digest/patch for standard/elevated; minor for
  standard. App non-major updates are normally auto-merged by Renovate after
  `test`; the skill only handles exceptions.
- **Tier B** — research, then merge autonomously if clean: minor for elevated;
  digest/patch for critical; 0.x or chart bumps with no breaking signals.
- **Tier C** — user consent: app or Infra major; k8s minor; 0.x minor with
  breaking signals or manual migrations; critical components at minor or above;
  DB engines. App majors are dashboard-gated by Renovate and need approval
  before a PR is opened.
- **Infra PRs** — always the human gate. The skill researches and validates,
  then waits for explicit approval before merging. This is separate from the
  deploy consent.
- Escalate one tier when unsure. A Tier C merge and its deploy are separate
  consent asks.

## Research recipes

### k3s / Plan versions

- `curl -s https://api.github.com/repos/k3s-io/k3s/releases/tags/<vX.Y.Z%2Bk3sN>` —
  check `prerelease`, `published_at` (prefer a stable release at least a few days old),
  and the change list: note bundled Traefik, Gateway API CRD, containerd, etcd, and
  helm-controller bumps.
- Search for fresh regressions:
  `.../search/issues?q=repo:k3s-io/k3s+is:issue+is:open+<version>`.
- Check Longhorn compatibility with the new Kubernetes minor before recommending.
- Deploying is a rolling upgrade of every node (server-plan first, then agent-plan) —
  always treat as a maintenance-window action with a fresh backup.

### App minors and 0.x bumps

- Read the upstream changelog/releases for breaking changes, config/env renames, and
  migration steps.
- For apps with a database: check whether migrations are automatic and additive
  (low risk) or manual/destructive (Tier C). Example: opodsync 0.6.0 auto-migrates
  with index-only SQL — safe.
- App PRs merge with squash; the default-branch `publish` job then pushes and
  verifies `:sha-<commit>` and promotes `:latest`. A green `test` only built a
  local image.
- The next scheduled Renovate run opens the first-party Infra digest PR
  immediately (the `ghcr.io/imranr98/**` allowlist). Third-party images wait
  3 days. Do not hand-edit a digest; if a first-party PR is missing after a
  successful publish, run `bash scripts/renovate.sh infra` and recheck.
- If the app merge only touched docs/workflow/Renovate config, the publish is
  skipped; no digest PR will appear.
- `renovate/stability-days: pending` is the age gate. Leave the PR for
  Renovate; first-party app pins should not be pending, so investigate one that
  is.

### Digest refreshes under a floating tag

Verify the digest exists and identify the real version behind it:

- Docker Hub images (including `lscr.io` linuxserver mirrors):
  `curl -s https://hub.docker.com/v2/repositories/<repo>/tags/latest` → `digest`, `last_updated`.
- ghcr.io:
  `TOKEN=$(curl -s 'https://ghcr.io/token?scope=repository:<repo>:pull' | jq -r .token)` then
  `curl -sI -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' 'https://ghcr.io/v2/<repo>/manifests/latest'`
  → `docker-content-digest`.
- To learn the version behind `latest`, read the image config label
  `org.opencontainers.image.version` or infer from upstream release timing.
- A pinned digest may lag the current `latest` (the PR opened earlier) — still valid;
  Renovate refreshes later.

### 3-day age gate and channel-only images

- `minimumReleaseAge` is 3 days for every update type. Renovate compares the
  candidate's release timestamp; a mutable tag rebuilt more often than every
  3 days is always "too new" and never becomes eligible.
- The narrow `renovate.json` allowlist covers only first-party app images
  (`ghcr.io/imranr98/**`), LinuxServer `latest`, ComfyUI `xpu-master`, llama.cpp
  channel tags, and the temporary Bitnami DB pins. Their digest PRs appear
  immediately.
- Everything else must use an immutable version tag (semver, CalVer/build,
  exact patch + distro). If a non-allowlisted image has been pending for more
  than 3 days, verify the registry tag timestamps: pin a more specific tag, or
  add a justified allowlist entry. Never reintroduce a broad 0-day digest rule.

### Helm charts

Check the upstream chart changelog for removed/renamed values and changed defaults,
then run `validate.sh srv0` (renders both charts and rejects `<no value>`).

## Repo-specific couplings and gotchas

- immich server and machine-learning must move together, both at `vX.Y.Z`; keep the
  `-openvino` suffix on the ML image.
- Grouped digest PRs contain many images — verify each.
- `renovate.json` blocks majors for postgres, clickhouse/clickhouse-server, fedora, and
  helm/helm; a PR that appears anyway is Tier C and needs investigation.
- k3s Plan bumps also roll k3s's bundled Traefik/coredns charts; after the upgrade
  confirm the `HelmChartConfig` customizations survived (Traefik args, Gateway
  `Programmed=True`, plugins).
- `nfs-apps` is the default StorageClass; do not add new Longhorn PVs. App data on
  a host path must use the statically bound `hostpath` PV/PVC whose `nodeAffinity`
  pins the owning node.
- App PRs use the shared preset (`github>ImranR98/Infra//renovate-preset`).
  Non-major updates are auto-merged by Renovate after the `test` check; majors are
  Dependency Dashboard approvals. If a major is approved and merged, it still
  goes through the app's own tests and image publish.
- App PR → image publish → Infra digest PR is a chain. Merge the app PR, let the
  `publish` job promote `:latest`, and let the next Renovate run open the
  first-party Infra digest PR; never pin an app whose publish failed. The Infra
  PR is the rollout gate and needs approval. `minimumReleaseAgeBehaviour:
  timestamp-required` plus `internalChecksFilter: strict` holds every
  non-allowlisted update until it is 3 days old.
- Compose syncthing/comfyui/llama are Renovate-managed now that watchtower is
  removed; srv0's K3s syncthing is Renovate-managed too.
- `scripts/check-images.sh` enforces exact tags + digests for raw image refs;
  the narrow channel-only allowlist is shared with `renovate.json`. Keep them
  in sync.
- Home Assistant's Frigate integration and Advanced Camera Card pins are
  `github-releases`-managed feature updates — check release notes for breaking config.
- k3s plan bumps: after merging, deployment is not done until both Plans report
  COMPLETE and nodes are Ready — see the upgrade-watch playbook.

## Worked examples

- **k3s `v1.36.4+k3s1` → `v1.37.0+k3s1`** — first stable of a new minor, days old,
  bundles a Traefik bump and Gateway API CRDs, rolling node upgrade. Tier C; held for
  consent, then deployed with the upgrade-watch playbook.
- **opodsync `0.5.3` → `0.6.0`** — 0.x minor; upstream changelog was features/fixes and
  the migration is automatic and index-only. Tier B; Renovate auto-merged it after
  the app tests passed.
- **`authelia/authelia:latest` digest refresh** — digest present, image label showed
  4.39.27 (patch on the same major). Tier B; presented for approval, then merged
  and deployed.
- **immich server + ML patch pair** — patch, coupled versions. Tier A/B; merge
  together as one Infra PR after approval.
