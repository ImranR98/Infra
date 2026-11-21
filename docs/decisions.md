# Decisions and invariants

Short records of the choices that are easy to accidentally undo.

## K3s on srv0, Compose elsewhere

`srv0` runs the Kubernetes workloads because the app set benefits from
Deployments/StatefulSets, Gateway routes, cert-manager, PVCs, and NetworkPolicies.
The satellite machines are simple enough for Compose. `srv0`'s public-exposure client
is a Compose sidecar on purpose: it must stay up when K3s is down so remote LUKS
unlock works.

## Multi-node capable, one node today

`srv0` is currently the only K3s node, but the cluster keeps embedded etcd,
`wireguard-native` flannel, `k3s-join.sh`, and the descheduler so a second node is
possible. The Main-data node is a singleton (`infra.local/hostpath-main`), and
`k3s-join.sh --hostpath-main` is the only supported way to move that ownership.

## Two security edges

`vps0` protects public traffic that terminates there; `srv0` protects its own origin
and the `home.*` tree. Both run Authelia, CrowdSec, and geoblock. This duplicates some
configuration but keeps each host independently defensible and avoids making srv0
depend on the VPS for its own auth.

## NFS retained

`nfs-apps` is the default RWX class and is backed by the in-cluster NFS server. The
measured NFS latency is accepted because several apps share bulk data and Postgres/
observability stores. `local-apps` handles SQLite and single-node POSIX workloads;
the static `hostpath` PVs pin the Main tree. Don't add another dynamic storage class.

## The six user-facing apps skip Authelia

Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, and Opodsync have their own
auth and deliberately have no forward-auth filter. `BOOTSTRAP_PRIVATE_APPS` keeps them
LAN/VPN-only while Authelia is being bootstrapped.

## Exact-SAN certificates

The two shared edge certificates list exact hostnames from `PUBLIC_HOSTS` and
`PRIVATE_HOSTS`; there are no wildcards or per-app certificates. Adding a host is a
deliberate `PUBLIC_HOSTS`/route change followed by re-issuance.

## Hardware is fixed

The board is AMD + VAAPI + ConBee, and the charts hardcode the matching backends:
Frigate/Immich ML on `infra.local/amd-igpu`, Jellyfin/Immich server on
`infra.local/vaapi`, Home Assistant on `infra.local/conbee`. The generic device plugin
can still advertise Intel/dGPU resources; no chart uses them without an explicit
template change.

## Frigate model is downloadable

The YOLOv9 ONNX is published as the `frigate-model-v1` GitHub Release asset and fetched
by the `ensure-model` initContainer with SHA-256 verification. The model is not
committed; a local copy is gitignored.

## Renovate keeps Infra manual

App repos auto-merge non-major updates after `test`; Infra image/chart PRs are never
auto-merged because they change the running system. The digest allowlist is shared
between Renovate and `scripts/check-images.sh`.

## Multi-module apps ship as one suite

D4TA is the current example: `data.<SERVICES_DOMAIN>` serves the dashboard and all
modules from one chart and one config checkout. Do not reintroduce per-app hosts,
images, or deployment names.

## MTU and VPN notifications are deliberate

The public-exposure MTU watcher exists because the path MTU changed in production.
Keep it unless a replacement is measured. `conn-notify` intentionally alerts when a
remote-access peer comes online.

## ComfyUI is optional

The ComfyUI service in `targets/pc/compose/compose.yaml` is commented out and not
deployed. It is kept as an opt-in path for the Intel Arc iGPU; the image remains
allowlisted for that reason.

## Backups are label-driven

D4TA backs up PVCs labelled `auto-backup: "true"` and honours
`backup.infra/exclude`. Replaceable bulk media is deliberately not labelled. This keeps
the backup set aligned with app state rather than disk layout.
