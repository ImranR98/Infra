# Windows remote desktop (`win.$SERVICES_DOMAIN`)

Browser-only RDP gateway for the Windows machine on the LAN. Guacamole runs in
`srv0-apps`; the public path is the existing vps0 edge → public-exposure tunnel
→ srv0 Traefik. Authelia is the only human login; the Windows credentials are
prompted by guacd on each connection.

```
Mac browser ──TLS──> vps0 Traefik ──TLS passthrough──> WireGuard tunnel
            ──> srv0 Traefik (crowdsec → Authelia) ──> Guacamole → guacd
            ──RDP/TLS──> Windows:3389
```

- **Access:** `group:admins` and `group:family`, Authelia `one_factor`.
  The rule lives in `AUTHELIA_ACCESS_CONTROL_RULES` in
  `config/srv0/values.yaml`, not in the chart. The `family` group must contain
  the intended users in that same config file; otherwise only admins pass.
- **No geoblock** on this host (like `auth`); Authelia + CrowdSec are the gate.
- **No Windows credential is stored** in Guacamole: the seeded connection omits
  `username`/`password`, so guacd prompts for any Windows account.
- **No Guacamole admin UI step:** the schema and seed run in the
  `guacamole` Deployment's init containers; `guacadmin` is disabled.
- **Concurrency is unlimited in Guacamole:** the seeded connection uses
  `max_connections=0` and `max_connections_per_user=0`, so a new browser
  connection is not rejected with “connection in use.” Windows still decides
  whether a second RDP logon replaces the existing session or is allowed
  alongside it. If a stale session must be cleared, restart guacd
  (`kubectl -n apps rollout restart deploy/guacd`); that drops every active
  Guacamole session.
- The Windows firewall allows RDP from the LAN, so the Guacamole stack
  (`guacamole`, `guacd`, `guacamole-db`) is not pinned to a node.

## Windows machine (manual, one-time)

1. Windows **Pro/Enterprise** is required (Home cannot host RDP).
2. Enable **Remote Desktop** with **Network Level Authentication**.
3. Use an **existing Windows account** (no new account is required) or create
   a dedicated one if you prefer. Guacamole prompts for the username/password
   on every connect; nothing is stored. Add the account to **Remote Desktop
   Users** if it is not already allowed to sign in remotely.
4. Give the machine a static IP or DHCP reservation. Set
   `GUACAMOLE_WINDOWS_HOST` to that address; it must be reachable from the
   cluster nodes (same LAN).
5. Windows Firewall: allow TCP **3389** from the **LAN** (any local subnet
   address), not only srv0. Do not expose 3389 to the internet.
6. Disable sleep/hibernate when plugged in; control Windows Update reboots.
   The machine must be awake for a connection to succeed.

## Configuration

Committed defaults live in `targets/srv0/k3s-apps/values.yaml`:

```yaml
GUACAMOLE_WINDOWS_HOST: "<windows-ip>"
GUACAMOLE_WINDOWS_PORT: "3389"
GUACAMOLE_DB_STORAGE: "2Gi"
GUACAMOLE_DB_PASSWORD: ""   # generated once and reused if empty
```

Override any of them in the gitignored `config/srv0/values.yaml`. The host must
be an **IP**: the guacd egress NetworkPolicy is a `/32` ipBlock. The seed init
container updates the RDP parameter on the next `srv0-apps` upgrade, and the
Deployment checksum restarts the pod.

The DB password is generated on first deploy and reused from the existing
Secret via Helm `lookup`. If `GUACAMOLE_DB_PASSWORD` is set, set it **before**
the first deploy; changing it after the DB exists requires rotating the
Postgres password too.

## Deploy

```bash
bash scripts/validate.sh srv0
bash scripts/deploy.sh srv0
```

`srv0-base` must land first: it adds `win.$SERVICES_DOMAIN` to
`edge-public-tls` (the `PUBLIC_HOSTS` SAN set) and the Authelia rule. cert-manager re-issues
the shared certificate; the public route is served once the new secret is
ready. `srv0-apps` then creates the Secret/PVC/ConfigMap, Postgres, guacd,
Guacamole, NetworkPolicies, and the HTTPRoute.

## Verify

```bash
kubectl -n base get certificate edge-public-tls -o jsonpath='{.spec.dnsNames}' | tr ' ' '\n' | grep '^win\.'
kubectl -n apps logs deploy/guacamole -c db-init
kubectl -n apps exec deploy/guacamole-db -- \
  psql -U guacamole -d guacamole -c \
  "SELECT e.name, u.disabled FROM guacamole_entity e JOIN guacamole_user u USING (entity_id);"
kubectl -n apps exec deploy/guacamole-db -- \
  psql -U guacamole -d guacamole -c \
  "SELECT connection_name, protocol, max_connections, max_connections_per_user FROM guacamole_connection;"
curl -sI https://win.$SERVICES_DOMAIN | head -5   # 302 to auth (no geoblock 403)
```

Expected DB rows: `shared` enabled, `guacadmin` disabled, one `Windows` RDP
connection.

## Guest flow

1. Open `https://win.$SERVICES_DOMAIN`.
2. Authelia login (admins/family; one factor for this host).
3. Click **Windows**.
4. Enter the shared Windows username/password (`user`, `MACHINE\user`, or
   `MicrosoftAccount\email`). The desktop opens in Safari/Chrome; no client or
   VPN install is needed.
5. Guacamole's menu provides the on-screen keyboard, clipboard, and full-screen
   controls.

Revoke access by removing the person from the `admins`/`family` group in
Authelia (or disabling the account). The Windows account is shared by design;
disable or change it separately if needed.

## Notes / maintenance

- Guacamole and guacd are pinned together at `1.6.0`; bump both in
  `targets/srv0/k3s-apps/templates/guacamole.yaml`. Guacamole JDBC schema
  upgrades are not automatic — check the release notes and apply the matching
  `schema/upgrade/*.sql` before/with a bump. The init container only creates the
  schema when `guacamole_entity` is absent.
- `win-header-auth` (in `targets/srv0/k3s-base/templates/traefik.yaml`) sets
  `X-Guac-User: shared` after forward-auth, overwriting any client value. The
  Guacamole Service is ClusterIP; NetworkPolicies admit only Traefik (webapp)
  and the webapp (guacd/DB), so the header cannot be forged from the LAN.
- The guacd egress policy admits only `GUACAMOLE_WINDOWS_HOST:3389`; the apps
  namespace's default-deny egress blocks every other LAN destination.
