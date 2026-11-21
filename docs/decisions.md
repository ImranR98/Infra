# Decisions and invariants

Short records of the choices that are easy to accidentally undo. Details live in the
linked pages.

## K3s on srv0, Compose elsewhere

`srv0` runs Kubernetes because its app set uses Deployments, Gateway routes,
cert-manager, PVCs, and NetworkPolicies. The satellites are simple enough for Compose.
The public-exposure client stays a Compose sidecar so it survives a K3s outage. See
[Architecture](architecture.md).

## Multi-node capable, one node today

`srv0` is currently the only K3s node, but the cluster keeps embedded etcd,
`wireguard-native` flannel, the join script, and the descheduler so a second node stays
possible. The Main-data owner is a singleton. See
[Platform: multi-node](platform.md#multi-node).

## Two security edges

`vps0` protects public traffic that terminates there; `srv0` protects its own origin
and the `home.*` tree. Both run Authelia, CrowdSec, and geoblock. The duplication is
deliberate: each host stays independently defensible. See
[Public edge](public-edge.md).

## NFS retained

NFS latency is accepted because several apps share bulk data and the observability
stores. `local-apps` covers SQLite/POSIX workloads and the static `hostpath` PVs pin
the Main tree. See [Platform: storage](platform.md#storage).

## The six user-facing apps skip Authelia

These apps have their own auth and deliberately have no forward-auth filter. See
[Apps: user-facing apps](apps.md#user-facing-apps).

## Exact-SAN certificates

The shared edge certificates use exact hostnames from `PUBLIC_HOSTS`/`PRIVATE_HOSTS`;
there are no wildcards or per-app certificates. See [Public edge](public-edge.md).

## Hardware is fixed

The board and backends are fixed in the charts, not selected through a profile. See
[Platform: hardware](platform.md#hardware).

## Frigate model is downloadable

The detector model is fetched at pod start and digest-verified, not committed. See
[Apps: Frigate model](apps.md#frigate-model).

## Renovate keeps Infra manual

App repos auto-merge non-major updates; Infra image/chart PRs stay a manual rollout
gate. See [Operations: updates](operations.md#updates).

## Multi-module apps ship as one suite

D4TA is the current example; its modules share one host, chart, and config checkout.
See [Apps: D4TA](apps.md#d4ta-multi-module-suite).

## MTU and VPN notifications are deliberate

The public-exposure MTU watcher and VPN connection notifications exist for real
production reasons. See [Tunnels](tunnels.md).

## ComfyUI is optional

ComfyUI is committed but commented out and not deployed. See
[Apps: optional ComfyUI](apps.md#optional-comfyui-on-pc).

## Backups are label-driven

The backup set follows PVC labels rather than disk layout. See
[Platform: storage](platform.md#storage) and
[Operations: backups](operations.md#backups).
