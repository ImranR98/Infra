# Platform

`srv0` runs K3s; the documented non-K3s targets run Docker Compose. The cluster is
deliberately multi-node-capable: other Kubernetes nodes may exist but are not shown in
the target table.

## K3s on srv0

- One control plane, embedded etcd (`cluster-init: true`), `flannel-backend:
  wireguard-native`.
- `scripts/k3s-server.sh` installs K3s, writes the server config, starts it, and sets
  the node labels `infra.local/hostpath-main=true` and
  `infra.local/external-exposed=true`.
- `scripts/k3s-node-prep.sh` applies sysctls and the firewall ports/trusted CIDRs
  (API, etcd, flannel, Traefik, kubelet, VPN subnets).
- `scripts/k3s-join.sh` adds a server or agent. `--hostpath-main` moves the Main-data
  label to a replacement node; that label is a singleton.
- `descheduler` stays deployed for multi-node taint cleanup; with a single node it is
  effectively a no-op. `system-upgrade-controller` owns K3s upgrades through the Plans
  in `system-upgrade.yaml`.
- The admin kubeconfig is root-only; use `scripts/kubeconfig-unlock.sh`.

### Multi-node

The etcd backend, `wireguard-native` flannel, join script, and descheduler are kept
specifically so additional nodes can be added. Before adding one, check:

- the new node reaches etcd ports `2379/2380` and flannel ports;
- exactly one node carries `infra.local/hostpath-main=true`;
- the `nfs-server` and the static `hostpath` PVs stay on that Main-data node;
- `k3s-join.sh --hostpath-main` is used only when replacing the Main-data owner.

## Releases and namespaces

| Release | Namespace | Contents |
|---|---|---|
| `srv0-base` | `base` | namespaces, storage, security, Traefik/Gateway, cert-manager, monitoring, NFS, Renovate, VPN |
| `srv0-apps` | `apps` | app workloads + the D4TA chart dependency |

Apply `base` first, then `apps`; delete in reverse order. Both use
`targets/srv0/k3s-*/values.yaml` plus `config/srv0/values.yaml` and depend on the local
`k3s-common` library chart for shared helpers. Upstream charts are installed as
`helm.cattle.io/HelmChart` CRs, so the Helm release completing is not the end of the
rollout.

## Edge and routing

- Traefik runs as a DaemonSet with hostPorts and no Service; the Gateway API is the
  routing layer. See [Public edge](public-edge.md).
- cert-manager issues the two shared edge certificates from `edge-certs.yaml`.
- The `srv0` Gateway has `web`, `websecure`, and `websecure-proxy` listeners; all
  `HTTPRoute`s live in `base` so they can reference the shared Middlewares.

## Hardware

The generic device plugin generates resources from sysfs and `/dev` at startup:

| Resource | Current use |
|---|---|
| `infra.local/amd-igpu` | Frigate ROCm detector, Immich ML |
| `infra.local/vaapi` | Jellyfin, Immich server |
| `infra.local/conbee` | Home Assistant ConBee II |
| `infra.local/intel-gpu`, `infra.local/amd-dgpu` | Advertised by the plugin; no chart uses them |

The configuration is fixed in the charts: Frigate and Immich ML use ROCm on
`amd-igpu`, Jellyfin/Immich server use VAAPI, and Home Assistant always mounts the
ConBee II and host Bluetooth socket. There is no `GPU_PROFILE` matrix. The plugin can
still advertise Intel/dGPU resources if the hardware changes, but workloads must be
updated explicitly.

## Resource sizing

Every container picks a tier from `infra.resources` (shared by `k3s-base` and
`k3s-apps` through the local `k3s-common` library chart). Raw `memory:`/`cpu:` keys
are rejected by `validate.sh`.

| Tier | CPU request | Memory request | Memory limit |
|---|---|---|---|
| `tiny` | 10m | 32Mi | 128Mi |
| `small` | 10m | 64Mi | 256Mi |
| `medium` | 25m | 128Mi | 512Mi |
| `large` | 50m | 256Mi | 1Gi |
| `xlarge` | 50m | 512Mi | 2Gi |
| `2xlarge` | 100m | 1Gi | 4Gi |
| `3xlarge` | 250m | 2Gi | 8Gi |

The tiers come from cadvisor history: memory request = smallest tier at or above the
7-day p50; memory limit = 4x the request (bumped a tier if below the observed peak);
CPU request = the tier value. Requests across both charts must fit the node
allocatable (16 CPU / ~30GiB).

Three narrow deviations, each with an inline comment:

- `memLimit` raises the ceiling for rare real bursts (`linkwarden` 16Gi, `opencode`
  4Gi); the request stays on the tier.
- `cpu` overrides the CPU request when CPU and memory disagree (`d4ta-tags` 1,
  `syncthing` 500m, `logtfy` 50m).
- `custom` is for model/cache memory (`immich-machine-learning` 1Gi/8Gi) and requires
  explicit `memRequest` and `memLimit`.

CPU limits stay off unless the chart sets one or the workload takes untrusted input
(`crowdsec` 500m, `falco` 1, `prometheus` 1, `logtfy` 1).

## Storage

Three storage paths:

| Class | Backing | Use |
|---|---|---|
| `nfs-apps` | NFS CSI, `nfs-server.base.svc.cluster.local`, share `/apps` | Default RWX app data; Postgres and observability stores |
| `local-apps` | Dedicated local-path provisioner, `~/infra_state/k3s_live_state/app-data` | SQLite and single-node workloads that need a real filesystem; RWO |
| `hostpath` | Static PV/PVC with `nodeAffinity` on `infra.local/hostpath-main` | The Main tree and other host-owned data |

The NFS server exports:

- `/exports` — NFSv4 pseudo-root
- `/exports/media` — read-only `Main/Media`, used as `/media/Music`, `/media/TV`,
  `/media/YouTube`
- `/exports/apps` — dynamic `nfs-apps` volumes
- `/exports/code-sandbox` — OpenCode sandbox host path

The static `hostpath` claims cover the Main tree (`main`, `devicesync`,
`d4ta-watxt`, `file-pipelines`, `backups`, `media`, `documents`, `whatsapp`), the
journal directory for Logtfy, and the D4TA config/ledger checkouts. Do not add other
dynamic PVs; don't replace host-path app data with a raw `hostPath` mount.

PVCs labelled `auto-backup: "true"` are copied by the D4TA backup task. Use
`backup.infra/exclude` for rebuildable caches. Media, recordings, and other
replaceable bulk data are deliberately not labelled.

See `targets/srv0/k3s-base/templates/nfs-server.yaml`, `local-apps.yaml`,
`host-volumes.yaml`, and `targets/srv0/k3s-apps/templates/d4ta-storage.yaml`.

## Helm

Only project-maintained charts are allowed; `validate.sh` enforces the allowlist.
Home Assistant is the single third-party exception. Pin `image.repository`/
`image.tag` on app-version-sensitive charts so Renovate tracks the app, not just the
chart.

## Compose targets

`vps0`, `bigpc`, `pc`, and `rpi` use Docker Compose from their own checkout. Always
pass the machine-fact `targets/<t>/compose/.env`, plus
`config/<t>/compose.env` where a `config_template` exists (`vps0`, `bigpc`; `srv0`'s
sidecar uses `config/srv0/compose.env`). `pc` and `rpi` have no config env.
