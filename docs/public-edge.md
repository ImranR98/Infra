# Public edge and security

Two Traefik instances and two security stacks, each responsible for the traffic that
terminates on its host.

## vps0 — public entry point

`targets/vps0/compose/compose.yaml` runs Traefik with:

- entrypoints `web` (:80), `websecure` (:443), `rtmp` (:1935)
- ACME via TLS-ALPN-01; no HTTP challenge interception, so `srv0`'s cert-manager
  HTTP-01 challenges can pass through the tunnel
- Docker provider on a socket proxy (`dockerproxy`)
- Cloudflare `X-Forwarded-For` trust for the Cloudflare-proxied hostnames
- a catch-all HTTP → HTTPS redirect

Middlewares (file provider):

- `authelia` — forward-auth to `auth.<CLOUD_SERVICES_DOMAIN>`
- `crowdsec-bouncer` — stream mode against the local CrowdSec LAPI + AppSec
- `geoblock` — country allowlist via `get.geojs.io`
- `public-exposure` TCP router — `HostSNI(home.*)` to `10.99.0.2:8443` with
  PROXY protocol

`traefik-logrotate` caps the access log that CrowdSec reads. Public app hostnames are
defined by the Compose labels under `CLOUD_SERVICES_DOMAIN` / `BASE_SERVICES_DOMAIN`.

## srv0 — private origin and public tunnel target

`srv0` runs the K3s Traefik DaemonSet with three listeners:

| Listener | Port | Use |
|---|---|---|
| `web` | 80 | HTTP redirect / ACME |
| `websecure` | 443 | LAN and VPN clients |
| `websecure-proxy` | 8443 | public-exposure tunnel only |

Gateway API is the routing layer: one `Gateway/srv0` in `base`, with `HTTPRoute`s in
the `base` namespace. The two shared certificates are:

- `edge-public-tls` — every hostname in `PUBLIC_HOSTS`; attached to `websecure` and
  `websecure-proxy`
- `edge-private-tls` — every hostname in `PRIVATE_HOSTS`; attached only to
  `websecure`

Exact SANs, no wildcards and no per-app certificates. Adding a public host means
adding its label to `PUBLIC_HOSTS` and its `HTTPRoute`, then re-issuing the edge
certificate. `validate.sh` checks route/SAN drift and Gateway certificate references.

## Authentication and access control

- **Authelia** guards the routes that need SSO. On `srv0`, the deployment, Postgres,
  Redis, OIDC clients, and the final admin catch-all are in the chart; deployment
  group/user rules come from `AUTHELIA_ACCESS_CONTROL_RULES` in
  `config/srv0/values.yaml`.
- On `vps0`, structural bypasses live in the chart and deployment-specific rules live
  in `config/vps0/authelia/access_control.yml`, rendered by
  `scripts/render-vps0-authelia.sh`.
- The six user-facing apps (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome,
  Opodsync) deliberately have **no** Authelia forward-auth filter; they rely on their
  own auth. `BOOTSTRAP_PRIVATE_APPS` keeps them LAN/VPN-only during first boot.
- **CrowdSec** runs on `vps0` and `srv0`; the srv0 chart includes the LAPI, agent,
  AppSec, and a cert-roll CronJob. Do not add personal group names to charts.
- **Falco** and **OpenCanary** are separate detection systems, documented in
  [Observability](observability.md#falco-and-opencanary).

## Adding a public app

1. Deploy the workload with a Service and an `HTTPRoute` in `base`.
2. Add the host label to `PUBLIC_HOSTS` in `config/srv0/values.yaml`.
3. If the app lives on `vps0`, add its Traefik labels under the right domain.
4. Choose auth: Authelia forward-auth, app-native auth, or private-only.
5. Run `bash scripts/validate.sh srv0` (and `vps0` if touched).
6. Re-issue `edge-public-tls` via the next `srv0-base` deploy; verify the certificate
   covers the new SAN.

For private-only names, add to `PRIVATE_HOSTS` instead and keep the route off the
`websecure-proxy` listener.
