# AGENTS.md — Infra Repository Guide

Single-repo, shell-driven infrastructure-as-code managing a homelab of Linux machines.
One entry point: `./infra.sh <target> <command...>`.

## Architecture

```
targets/<target>/
├── VARS.template.sh          # Declares all required variables (placeholders)
├── commands/                  # Target-specific command overrides
├── compose/                   # Docker Compose services for this target
│   ├── compose.yaml           # Compose file with $VAR references
│   └── templates/             # Per-component template files
│       └── <component>/
│           ├── prep.sh        # Pre-render hook (runs once per component)
│           └── *.secret       # envsubst + chmod 600
│           └── *.plain        # Copy as-is
└── k3s/                       # K3s components for this target
    ├── groups.yaml            # Ordered deployment (base → apps)
    └── <component>/
        ├── kustomization.yaml # Required. Lists resource YAMLs.
        ├── prereqs.yaml       # PVCs, Secrets, ConfigMaps (apply first)
        ├── <app>.yaml         # Deployment/StatefulSet/Service
        ├── helmchart.yaml     # HelmChart CR (alternative to raw manifests)
        ├── ingress.yaml       # cert-manager Certificate + Traefik IngressRoute
        ├── network-policy.yaml
        ├── prep.sh            # Pre-apply hook
        ├── post.sh            # Post-apply hook (e.g., API setup)
        └── delete.sh          # Pre-deletion cleanup
```

VARS files (gitignored, at repo root):
- `VARS.<target>.sh` — actual secrets (exported variables)
- `VARS.template.sh` — located in each `targets/<target>/` directory

## Adding a new K3s app

1. `mkdir targets/<target>/k3s/<app>/`
2. Create `kustomization.yaml` — list all resource YAML files
3. Create `prereqs.yaml` — PVCs, Secrets, ConfigMaps. The Secret's `stringData` can use
   bare `$VAR` references; they'll be expanded by envsubst before kubectl sees them.
4. Create `<app>.yaml` — Deployment (or StatefulSet) + Service
5. Create `ingress.yaml` — cert-manager Certificate + Traefik IngressRoute
   - Public route: `Host(<sub>.$SERVICES_DOMAIN)` on `websecure` + `websecure-proxy`
     with middleware stack: `geoblock → crowdsec-bouncer → forwardauth-authelia`
   - LAN route (if needed): `Host(<app>.home.lan)` on `websecure` only, with `lan-whitelist`.
     No cert-manager Certificate. No `websecure-proxy` entrypoint. `tls: {}`
6. Add new VARS to `targets/<target>/VARS.template.sh` and to the gitignored VARS file
7. Add `<app>` to `groups.yaml` under `apps:` or `base:`
8. Deploy: `./infra.sh <target> k3s deploy <app>`
   - `initial` mode strips lines ending with `# IGNORE INITIALLY`

## Adding a new Compose service

1. Add service definition to `targets/<target>/compose/compose.yaml`
2. Add template files to `targets/<target>/compose/templates/<service>/` if needed
   - `.secret` files get envsubst + chmod 600
   - `.plain` files are copied as-is
   - `.secret` files support `# IGNORE INITIALLY` lines (commented out on first render)
3. Add any new VARS
4. Deploy: `./infra.sh <target> compose install` (renders templates, creates systemd unit, starts)

## Deploy pipeline (K3s)

Every deploy runs this exact pipeline:
1. **envsubst** — All `$VAR` and `${VAR}` references in YAML are expanded to shell values
2. **kustomize** — `kubectl kustomize` on the expanded YAML directory
3. **kubectl apply** — The rendered YAML is piped to `kubectl apply -f -`

In `initial` mode, step 1 is preceded by `sed '/# IGNORE INITIALLY$/d'` — lines ending
with `# IGNORE INITIALLY` are removed entirely before envsubst sees them.

Integer values in `env[].value` fields are automatically quoted (kustomize strips YAML quotes,
Kubernetes rejects bare integers in that field).

## VARS system

- `VARS.template.sh` declares every required variable with `export VAR="placeholder"`
- `VARS.<target>.sh` exports actual values (gitignored)
- On deploy, `source_env()` validates all template variables exist in the VARS file,
  sources them, then builds `ENVSUBST_VARS` as `$VAR1 $VAR2 ...` for envsubst
- Variables ending in `_HASHABLE` are auto-hashed via openssl:
  `AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE` → `AUTHELIA_IMMICH_CLIENT_SECRET_HASHED`
- `$MY_UID` is auto-set (1000 if root, else current UID)
- Multi-line variables use shell heredoc or literal newlines in quoted strings

## Storage

Three independent storage backends, deployed in this order:

### 1. hostpath (direct node storage)
- `local` PVs pinned to node via `nodeAffinity: hostpath-main=true`
- `storageClassName: hostpath`, `accessModes: [ReadWriteMany]`
- Used for bulk data already on disk: `$MAIN_PARENT_DIR`, device sync dirs, syslog
- The PV/PVC pairs use explicit `volumeName` binding
- **All pods touching hostpath PVCs MUST have `seLinuxOptions: { level: s0 }`**

### 2. NFS (shared read-only media)
- In-cluster NFS server pod (`ghcr.io/trexx/docker-nfs-server`) with privileged access
- CSI driver (`nfs.csi.k8s.io`) enables static PV creation pointing to in-cluster server
- Exports: music (ro), jellyfin-tv (ro), jellyfin-youtube (ro), arrstack-media (rw)
- PVs are static: each app creates a PV with `csi.driver: nfs.csi.k8s.io` and `volumeAttributes`
  pointing to `nfs-server.base.svc.cluster.local`

### 3. Longhorn (block storage for app state)
- Default StorageClass, single replica (safe for single-node)
- All Longhorn components pinned to `hostpath-main=true` node
- `ReadWriteOnce` access mode with auto-reattach for pod moves
- Backed up via `pvc-backup` CronJob (daily at 3am)

## Security

### Authelia
- ForwardAuth middleware on every public IngressRoute
- Authelia bypass rules (in `authelia/helmchart.yaml`) for apps with their own auth
- `# IGNORE INITIALLY` bypasses allow unauthenticated initial setup
- OIDC clients for Immich and Open WebUI
- Public ingress middleware chain: `geoblock → crowdsec-bouncer → forwardauth-authelia`

### CrowdSec
- LAPI (decision engine) + Agent (log reader) + AppSec (virtual patching, port 7422)
- Reads Traefik logs via `program: traefik` acquisition
- Custom whitelists for false-positive-prone apps go in the postoverflows directory:
  `/etc/crowdsec/postoverflows/s01-whitelist/`. The `prereqs.yaml` Secret mounts them there
  via the LAPI's `extraVolumeMounts`. Expression syntax uses `evt.Overflow.Alert.Events[0].GetMeta()`,
  NOT `evt.Meta.*` (which only works in old standalone whitelist files, not postoverflows).
- CrowdSec agent pod requires `seLinuxOptions: { type: spc_t }` (different from `s0`)

### SELinux
- **CRITICAL**: Zephyr+SELinux enforces MCS category isolation in Kubernetes.
  Any pod writing to a shared volume MUST match the SELinux level of other pods using the
  same volume. In this repo, the standard label is `s0`.
- **If a pod without `seLinuxOptions: { level: s0 }` writes to a hostpath PVC,
  other pods (syncthing, dscpln, mdscl, copyparty) will lose read/write access.**
- Fixed with: add `seLinuxOptions: { level: s0 }` to the pod `securityContext`,
  then run `sudo restorecon -R <affected-path>` on the host.
- Longhorn PVCs (block storage) don't need `s0` — only hostpath PVCs.
- `pvc.sh` backup/restore functions include `selinuxOptions: { level: s0 }` on temp pods.

## Gotchas and anti-patterns

### 🔴 SELinux: hostpath pods MUST have `seLinuxOptions: { level: s0 }`
Every pod touching a hostpath PVC needs `seLinuxOptions.level: s0`. Without it, files
created on the shared volume get a different MCS category and other pods can't access them.
See `copyparty.yaml`, `dscpln.yaml`, `syncthing.yaml`, `mdscl.yaml` for examples.

### 🔴 Linuxserver images (s6-overlay): NO `runAsUser` on pod
Images from `lscr.io/linuxserver/*` (qbittorrent, radarr, sonarr, prowlarr) use s6-overlay
internally. The pod `securityContext` must NOT set `runAsUser` or `runAsGroup` — s6-overlay
conflicts with Kubernetes UID manipulation. Instead, use env vars `PUID=$MY_UID` / `PGID=$MY_UID`.
Also avoid `fsGroup` — NFS chown fails on these volumes.

### 🔴 CrowdSec postoverflow expressions use `evt.Overflow.Alert.Events[0].GetMeta()`
Postoverflows run in the overflow context where `evt.Meta` does not exist.
All meta references must use the full path.
Example: `evt.Overflow.Alert.Events[0].GetMeta('http_verb') == 'GET'`

### 🔴 CrowdSec whitelists go in postoverflows, not config_dir
CrowdSec >= v1.6 ignores `*.whitelist.yaml` files in the config root directory.
Custom app whitelists must be mounted at `/etc/crowdsec/postoverflows/s01-whitelist/`.

### 🔴 `subPath` mounts don't auto-update when Secrets change
Kubernetes does not update `subPath` volume mounts when the backing Secret is modified.
After updating a Secret mounted via `subPath`, the pod must be restarted.

### 🔴 Longhorn PVCs need init containers for permission fixing
Fresh Longhorn PVCs are owned by root at mount time. Pods running as non-root
need an init container: `chown -R $MY_UID:$MY_UID /mount/path` (init container runs as root).

### 🟡 Service names can conflict with env vars
Kubernetes injects `SERVICE_NAME_PORT` env vars for every Service. If an app's
Go binary uses parsers that reject non-integer env values, rename the Service
(e.g., `gokapi-svc` instead of `gokapi`).

### 🟡 `lscr.io` images don't support `QBT_WEBUI_PASSWORD` or similar env-based password
qBittorrent's linuxserver image ignores `QBT_WEBUI_PASSWORD`. Use `post.sh` with API calls
via `kubectl exec` to configure passwords and preferences post-deploy.

### 🟡 Helm charts may not support PVC labels
If a Helm chart's PVC template lacks `labels:` support, use `config.persistence.existingClaim`
to reference a self-managed PVC with the desired labels (e.g., `auto-backup: "true"`).

### 🟡 `# IGNORE INITIALLY` is whitespace-sensitive
The regex is `/ # IGNORE INITIALLY$/` — only matches when the comment is at end of line
preceded by a space. Use `# IGNORE INITIALLY` on its own line, not inline.

### 🟡 `Recreate` strategy for single-replica hostNetwork pods
Deployments using `hostNetwork: true` or `hostPort` must use `strategy: Recreate` —
you can't have two pods binding the same host port.

### 🟡 Cert-manager Certificate blocks first deploy
The `ingress.yaml` Certificate requires the cert-manager issuer to be ready.
Either deploy cert-manager first via `groups.yaml` ordering, or `initial` mode
strips the `# IGNORE INITIALLY` dependency lines.

## Node labels

Set in `lib/k3s.sh` → `write_k3s_config()` and applied at K3s install time:
| Label | Purpose |
|-------|---------|
| `hostpath-main=true` | Node with `$MAIN_PARENT_DIR`. All hostpath PVs and Longhorn pinned here. |
| `hostpath-extra-storage=true` | Node with `/mnt/k3s_extra_storage/arrstack_media` |
| `external-exposed=true` | Node running externally exposed services (syslog hostPath) |

## Network topology

```
Internet → vps0:443 (vps0 Traefik)
    ├── Home services → FRP tunnel → srv0 K3s Traefik:8443
    ├── vps0-local services (Shlink, Uptime Kuma, Plausible, etc.)
    └── ACME: vps0 Traefik uses TLS-ALPN-01 challenge for `*.home.<domain>` certs

WireGuard → private LAN (10.x.x.x)
    ├── srv0: K3s control-plane, Cilium pod network (10.42.0.0/16)
    │   └── LAN routes: `*.home.lan` on Traefik `websecure` entrypoint (port 443)
    └── pc0: Owncast streaming via FRP through vps1
```

FRP tunnel port map (srv0 → vps0):
| Service | Local (srv0) | Remote (vps0) |
|---------|-------------|---------------|
| SSH | 22 | 8888 |
| SSH preboot | 22 | 8887 |
| HTTP | 80 | 8080 |
| HTTPS (K3s) | 8443 | 8443 |
| qBittorrent peer TCP | 31581 | 56881 |
| qBittorrent peer UDP | 31581 | 56881 |

## Commands quick reference

```
./infra.sh <target> k3s deploy <app> [mode]   # Deploy single component
./infra.sh <target> k3s group <group> [mode]  # Deploy all components in group
./infra.sh <target> compose install            # Render templates + install systemd unit
./infra.sh <target> compose restart <svc>      # Re-render + restart single service
./infra.sh <target> compose generate-frp-certs <server>  # Generate mTLS certs
./infra.sh <target> validate                   # Validate YAML + VARS references
./infra.sh <target> k3s backup-pvc --all -y    # Backup auto-backup PVCs
./infra.sh <target> k3s restore-pvc <name>     # Restore single PVC from backup
```

Modes: `apply` (default), `initial` (strips `# IGNORE INITIALLY`), `delete`, `diff`, `yaml`.

## Debugging

- SELinux file contexts: `ls -laZ` on the host or `kubectl exec` into a pod
- CrowdSec decisions: `kubectl -n base exec deploy/crowdsec-lapi -- cscli decisions list`
- CrowdSec alerts: `kubectl -n base exec deploy/crowdsec-lapi -- cscli alerts list`
- Check postoverflows loaded: `cscli postoverflows list`
- PVC backup status: check the CronJob logs in `apps` namespace
- Authelia logs: `kubectl -n base logs deploy/authelia`
- Traefik access logs: check traefik pod in `kube-system`
