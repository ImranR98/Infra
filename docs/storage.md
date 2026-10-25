# Storage

## App data — NFS (`nfs-apps`)

- The `nfs-server` pod (base) exports host paths; `csi-driver-nfs` mounts them. The **app-data export** is `/exports/apps` → `{{ .Values.INFRA_ROOT }}/current_target/k3s_live_state/nfs-apps`, with `no_root_squash` (needed by CSI subdir creation and Postgres chowns).
- The `nfs-server` image is built from `targets/srv0/k3s-base/nfs-server-src` and pushed to `ghcr.io/imranr98/nfs-server`; the Deployment pins the registry digest. Upstream `ghcr.io/trexx/docker-nfs-server` was archived in October 2026 and its GHCR package was deleted, so `build.sh` is the reproducible replacement. `.github/workflows/nfs-server-image.yml` rebuilds on `nfs-server-src` changes and weekly, verifies the image, and opens the digest re-pin PR; `build.sh` remains the local/emergency path. The image installs the latest `nfs-utils` and runs `apk upgrade --no-cache` for the pinned Alpine branch, so package updates are picked up by the weekly rebuild. It is tagged `latest`; the Deployment pins the digest. Alpine base updates are Renovate PRs (all update types; minor/major are reviewed as Tier C).
- The dynamic StorageClass **`nfs-apps`** is the **default** (`storageclass.kubernetes.io/is-default-class: "true"`). It provisions `subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}`, `mountPermissions: "0777"`, `reclaimPolicy: Retain`, `onDelete: retain`, `volumeBindingMode: Immediate`, `allowVolumeExpansion: false` (sizes are advisory; NFS has no quota).
- Migrated PVCs use **`ReadWriteMany`** so backup/restore pods can run on any node. The CSI driver is the only NFS client (hostNetwork node plugin); `nfs-server` ingress is allowlisted to the LAN CIDR (`allow-nfs-ingress`), all mounts use `nfsvers=4.2`.
- `opencode` splits its state: `opencode-home-pvc` is auto-backed-up (config, sessions, auth, SSH keys), while `opencode-tools-pvc` is intentionally unbacked and holds the Homebrew prefix/cache and nvm/Node versions under `/home/linuxbrew`; both toolchains are re-seeded from the image on first start after a loss.
- `openclaw` keeps config, sessions, workspace, and SQLite state on `openclaw-home-pvc` (auto-backed-up; `.cache` excluded). It stays on `nfs-apps` deliberately: OpenClaw detects NFS and uses SQLite DELETE journaling, but upstream warns that NFS is not its recommended storage; accept the same full-NFS SQLite tradeoff as the other apps. The same `code-sandbox` NFS share as opencode is mounted at `/sandbox` (RWX, not backed up), so coding-agent worktrees prepared in OpenClaw resolve to the same paths on the standalone OpenCode server. No host tree is mounted. `openclaw-config` seeds `openclaw.json`/`AGENTS.md`/`USER.md` only when each file is missing; delete the persisted copy and restart the pod to apply a chart-level config change. `agents.defaults.skipBootstrap: true` disables OpenClaw's no-clobber bootstrap publishes, which trip over NFS silly-rename; recreate missing bootstrap files manually rather than deleting them.
- `local-path` remains available but is not a default. The legacy `nfs-backup` class and tar rollback path were removed after the restic restore was verified; the old Longhorn SCs/PVs/volumes are gone.

## Shared media / static host paths

- `host-volumes` (base) defines the static `hostpath` PV/PVC pairs for the Main tree (media, music, documents, WhatsApp, backups, infra) pinned by `infra.local/hostpath-main=true`.
- The NFS media shares (`music`, `jellyfin-tv`, `jellyfin-youtube`, `arrstack-media`, `frigate`, `code-sandbox`) are static PVs using the `nfs` class name; they are not dynamically provisioned.
- Media deliberately stays on NFS (Frigate recordings, Jellyfin libraries, Immich external library) so pods can move nodes.

## Backups

- The **State Backups** task in D$CPLN Task Runner is the active backup system. It runs on a schedule (default Sundays 04:00) and has a manual **Run now**. One encrypted, deduplicated restic repository at `state_backups/restic` contains:
  - every PVC labelled `auto-backup=true` under `current_target/k3s_live_state/nfs-apps/<namespace>/<pvc>`,
  - the srv0 Compose state,
  - the vps0 Compose state, fetched over SSH with the existing key.
- The Task Runner backup instance runs as root in the `apps` namespace so it can read the Postgres/Redis-owned PVC data; it mounts the Infra tree read-only and only `state_backups/` writable. The vps0 Compose state is served by the generic `dscpln-agent` archive service; it holds no SSH key. The bigpc archive agent runs as a K3s Deployment.
- `retention` maps to `restic forget --keep-last N --prune` (default 7). Each run also does `restic check --read-data-subset=1%`.
- The repository lives in the Syncthing-replicated `Main/Infra` tree. Only srv0 should write it; wait for Syncthing to settle before restoring from a peer. The backup task keeps the repo root group-owned by `MY_UID` with the setgid bit, so every restic-created directory/file is readable by Syncthing; it also performs the one-time group migration of an existing repo. `restic/locks` is intentionally excluded from Syncthing.
- Syncthing's database/logs (`index-v2`) live on srv0 local disk at `~/.local/share/syncthing-data`, not on the `syncthing-config-pvc`. The config, certs and keys stay on the NFS PVC and are included in backups; the index is disposable and excluded from them.
- Restore is intentionally outside the app: `scripts/restic-restore.sh list`, `... pvc <name> [snapshot] [--live]`, and `... compose srv0|vps0 [snapshot] [--live]`. The script works on a fresh cluster and uses the repo/password/key directly.
- The old tar path (`pvc-backup`/`scripts/pvc.sh`, `compose_state_backups/`, `k3s_state_backups/`) was removed after the restic staged restore was verified on 2026-10-19.
- The restic password lives in the private `dscpln-config` checkout (`secrets/restic-password`, also mirrored into `secrets.json`); it is not in git or the public app repo. Record it off-cluster — a fresh restore needs it. Changing it after the repo exists requires `restic key add`/`restic key remove`; the backup task will not silently recreate the repo.

## NFS performance note

NFS is excellent for read-heavy/sequential workloads and media. SQLite/WAL and Postgres are latency-sensitive: on the migrated NFS volumes they are measurably slower than the old block storage (the benchmark measured ~3× SQLite p95 and ~2.6× Postgres latency under load). The full-NFS migration was chosen with that tradeoff accepted. The Immich Postgres image requires `IGNORE_DATABASE_FSTYPE=true` to start on NFS; it is set in `immich.yaml`. Prometheus also runs on `nfs-apps`; it logs an unsupported-filesystem warning (accepted, mirroring the old Mimir PVC) and its TSDB starts fresh with the Mimir cutover.
