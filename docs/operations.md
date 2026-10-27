# Operations

## Prerequisites

Bash 4+, Python 3, Docker Compose v2, kubectl (K3s targets), helm (srv0), yq, jq, curl, openssl, NFS client utilities, Node.js/npm for local Renovate runs. `scripts/prereqs.sh` prepares the machine: packages, the pinned helm binary, the official Docker bootstrap, the generated machine-fact `.env`, host bind dirs, and the seeded `acme.json`. It is idempotent — re-run after repo changes that add compose bind dirs.

## K3s & Helm

### Charts and releases

Two sibling charts — `targets/srv0/k3s-base/` and `targets/srv0/k3s-apps/` — applied with `helm upgrade --install`. They produce `srv0-base` (namespace `base`) and `srv0-apps` (namespace `apps`). Apply `base` before `apps`; delete in reverse (`srv0-apps` first) — Helm retains PVCs on uninstall. `validate.sh srv0` is the preflight.

The charts contain: (a) every repo-owned component as a Helm template — secrets, configmaps, HTTPRoutes, PVCs, the Task Runner backup RBAC, the Gateway/ReferenceGrants, the Traefik Middlewares/HelmChartConfig, the NFS server, the static host/NFS volumes; (b) the upstream-app `HelmChart` CRs (base + apps), owned by helm-controller; (c) vendored system-upgrade-controller manifests + Plans; (d) the immich seeding hook.

`k3s-base/` carries `files/` (generic-device-plugin config, alerting, dashboards, AmneziaWG scripts); `k3s-apps/` carries the app manifests and the pinned image digests.

`k3s-apps/templates/hooks.yaml` is the one seeding Job (`immich-seed`), annotated `helm.sh/hook: post-install,post-upgrade` with `hook-delete-policy: before-hook-creation,hook-succeeded` and RBAC through the `helm-hooks` ServiceAccount/Role. It skips when the admin already has an OAuth identity (`immich-admin list-users`, no auth needed); on a fresh DB it creates the admin through the sign-up API and persists the generated password in the `immich-seed-admin` Secret (apps). Other first-boot seeding is declarative: qBittorrent via a `qBittorrent.conf` ConfigMap + copy-once initContainer, and GeoLite2 is no longer used (geoblock calls `get.geojs.io`).

### Helm model

The helm binary is pinned by `prereqs.sh`; `upgrade --install` is idempotent (a three-way merge against the last stored manifest).

Three distinct "helm" layers:

1. **Our charts** → `srv0-base` / `srv0-apps`, via `helm upgrade --install`.
2. **k3s's embedded helm-controller** → the upstream-app `HelmChart` CRs inside our charts. Our releases only apply the CR objects; the controller installs and upgrades the app releases (immich, open-webui, …). `helm uninstall srv0-*` does not touch them — `kubectl delete helmchart` triggers their uninstall.
3. **k3s bootstrap charts** (traefik + traefik-crd in `kube-system`) — not ours; customized only through the `HelmChartConfig` template.

`helm-diff` is a plugin, not installed by `prereqs.sh`; install it to preview with `helm diff upgrade`.

### Helm chart policy

- Only charts maintained by the app's upstream project are allowed. `scripts/validate.sh` enforces the allowlist; adding a chart means updating both the allowlist and this policy.
- The single approved third-party exception is **Home Assistant** (`pajikos/home-assistant-helm-chart`): Home Assistant publishes no official chart, and the chart tracks HA releases closely.
- **Frigate, Ollama and Jellyfin run as raw manifests** in `targets/srv0/k3s-apps/templates/` with the official images; their Helm charts are gone.
- A chart that controls an app image must pin `image.repository` + `image.tag` (or the chart's equivalent) so Renovate tracks the app. The chart's `appVersion` alone is not a Renovate dependency; if the chart project lags, the app goes stale invisibly. The chart version is tracked separately.
- Chart-specific sidecars not pinned in `valuesContent` remain chart-managed; pin them only when their version matters.
- **Grafana/Loki chart source:** the OSS Grafana and Loki charts moved to `grafana-community/helm-charts` (#4087); the current pins are Grafana chart 14.0.1 (app 13.2.4) and Loki chart 18.17.1 (app 3.7.8). The old `grafana/helm-charts` copies are frozen/GEL-only for Loki; `k8s-monitoring` remains on `grafana/helm-charts`. Do not pin the chart sidecars individually.

### Pitfalls

- `helm lint`/`helm template` need both values files (`-f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml`; the same config file feeds both charts). Without them `.Values.X` is nil and lint fails with `invalid value; expected string`. Missing keys render as `<no value>` — `validate.sh` catches those.
- `.Files.Get` paths are chart-root-relative; the `files/` prefix is mandatory. Omitting it silently renders empty.
- Literal `{{` is interpreted by helm — homeassistant's embedded Go templates are escaped as `{{ "{{" }}`.
- Subchart resource names derive from `{{ .Release.Name }}` — the reason the app charts stay HelmChart CRs (helm-controller-managed) instead of becoming umbrella dependencies.
- Never `helm install --force` casually — it deletes and recreates resources.
- Don't validate rendered output with `kubectl apply --dry-run=server` (it trips on the 256KiB `last-applied-configuration` cap); use helm's own `--dry-run=server`.
- Adoption: pre-existing objects need `app.kubernetes.io/managed-by: Helm` plus the `meta.helm.sh/release-name`/`release-namespace` annotations, or helm refuses to install over them. The `nfs-apps` StorageClass is Helm-owned; the static NFS PVCs are chart-owned.
- `helm uninstall` ignores live-object annotations — `helm.sh/resource-policy: keep` only takes effect from the stored manifest.

### Kubeconfig access

`/etc/rancher/k3s/k3s.yaml` is `0600 root:root` (k3s sets `write-kubeconfig-mode: "0600"`), so users have no standing access. `scripts/kubeconfig-unlock.sh` grants the invoking user a temporary read ACL on it and symlinks `~/.kube/config` to it, blocking until Ctrl-C removes both (`--lock` cleans leftovers). A k3s restart rewrites the kubeconfig and clears the ACL mask; while the unlock is held, its watchdog re-asserts the ACL every 15s. Host-side `restic-restore.sh` runs also belong inside an unlock session; the Task Runner backup task uses its own ServiceAccount.

### Node provisioning

Owned by `k3s-server.sh` and `k3s-join.sh` (official get.k3s.io installer). Cluster policy lives in the scripts:

- **`k3s-server.sh`** (no args, on the node): runs `k3s-node-prep.sh` (sysctls in `/etc/sysctl.d/90-k3s.conf`; enables nothing Longhorn-specific; firewalld/ufw rules — cluster ports including 51820–21/udp for flannel-wg and 10250/tcp, which stays open because clustered Alloy may scrape a peer's kubelet, while 9100 is dropped since node-exporter is unauthenticated and scraped on the pod network; server nodes also get a `kubepods.slice` `IOWeight=10` and an idle-priority `fstrim.service` drop-in — the weight only binds on elevators that honor it, so it is inert where the device runs `none`, and only fstrim's CPU priority applies), the installer, and `/etc/rancher/k3s/config.yaml` (`selinux: true`, `write-kubeconfig-mode: "0600"`, `flannel-backend: wireguard-native`, `cluster-init: true`, `node-ip`, plus `kube-controller-manager-arg`/`kube-scheduler-arg`/`kube-cloud-controller-manager-arg` lease tolerances (3m/2m/10s) so minute-scale etcd write stalls don't exit k3s), then restarts, waits for the server token and the API, and sets the static node labels `infra.local/hostpath-main=true` and `infra.local/external-exposed=true`. Node feature labels are **not** NFD-managed anymore; no `node.longhorn.io` labels.
- **`k3s-join.sh <node_ip> <node_user> [...]`** (on the control plane; the sudo prompts for the control plane and the joining node are separate, as they may differ): reads the token from `/var/lib/rancher/k3s/server/token`, resolves the server IP, streams `k3s-node-prep.sh` + the installer over SSH with the token appended on stdin (never argv — it lands in the node's root-only `k3s-agent.service.env` for agents, or `config.yaml` for joined servers), waits for the node to appear and become Ready, then applies the taint and (optionally) `infra.local/hostpath-main=true`. Flags: `--role agent|server`; `--scheduling-discouraged` (PreferNoSchedule taint); `--hostpath-main` (label the joined node for the Main host paths). The installer runs only when k3s is missing, so re-provisioning never fights system-upgrade-controller's version ownership. SSH host-key checking stays at the default (on): the first join prompts to accept the fingerprint, the same trust model as plain `ssh`.
- **`update-node-ip.sh`** (bash, on the node): sed-replaces `node-ip` in drop-ins and adds `50-node-ip.yaml`; updates etcd member peer URLs *before* restarting k3s (k3s is `Type=notify` — a synchronous restart deadlocks), restarts with `--no-block`, then patches the node's flannel public-ip annotation and status addresses. Installs etcdctl on demand.

### system-upgrade

The controller manifests are vendored in `templates/system-upgrade-controller.yaml` (downloaded from `releases/latest` of rancher/system-upgrade-controller; bump by re-downloading `crd.yaml` + `system-upgrade-controller.yaml` and replacing the template — the controller image inside is Renovate-managed via the kubernetes manager). `server-plan`/`agent-plan` versions (`vX.Y.Z+k3sN`) are Renovate-managed by the plan-version regex. Once bumped: apply `srv0-base`, then inspect with `kubectl -n system-upgrade get plans,jobs`.

### valuesSecrets

HelmChart CRs can pull values from a namespaced Secret via `spec.valuesSecrets: [{name, keys}]`: each listed key is projected as a `values-0-00N-HelmChart-ValuesSecret.yaml` file merged after `valuesContent` (plain Helm deep-merge, later file wins; `keys` must be non-empty). No chart currently uses this after the Frigate raw-manifest migration; the feature remains available. Secret changes re-trigger the chart upgrade (`ignoreUpdates: false` default). The Secret must live in the CR's namespace and must not be named `chart-values-<chart>`.

### Bootstrap-private apps (srv0)

`BOOTSTRAP_PRIVATE_APPS` (default `"false"` in `k3s-apps/values.yaml`; optional config override) removes the `websecure-proxy` parentRef from Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome and Opodsync, so those six are LAN/VPN-only until Authelia is Ready. Set it to `"true"` for first boot, then `"false"`. The custom header-gate WASM plugin/chain is gone; the six routes have no Authelia forward-auth (their own auth handles login). `validate.sh` prints a warning while the flag is true.

## Alerting (Grafana → ntfy)

- Grafana provisions one webhook contact point (`ntfy`, write-only token in the `grafana-alerting-contact` Secret from `NTFY_WRITE_ONLY_ACCOUNT_TOKEN`) plus file-backed alerting config from the `grafana-alerting-rules` ConfigMap: 26 rules (`files/alerting/rules.yaml`) in the **Falco** folder, the policy tree (`policies.yaml` — receiver ntfy, `group_by: alertname`, 12h repeat), and the markdown body template group (`templates.yaml`, `ntfy.body`). The cert-manager ServiceMonitor is scraped for certificate expiry/readiness alerts; the stale Longhorn rules were removed with Longhorn.
- The templated webhook URL carries the dynamic ntfy fields (Extra Headers can't change per alert): `title` = alertname, `priority` = low on resolved / high on warning / urgent on critical / default otherwise, `markdown=yes`. `ntfy.body` renders the markdown body — state + name, summary, and the labels worth seeing — instead of the default `Value:`/`Labels:` dump.
- Title URL-encoding order matters: `%`→`%25` first, then spaces→`%20` (the reverse re-escapes the `%` of `%20`).
- Certificate/NFS rules: `cert-manager-expiry` warns when a certificate has less than 21 days left, `cert-manager-not-ready` is critical, and `nfs-server-unavailable` fires when the NFS Deployment has no available replicas. cert-manager metrics are enabled via its ServiceMonitor and scraped by k8s-monitoring's `prometheusOperatorObjects`; the NFS rule uses kube-state-metrics.
- Falco alerting: `falco-daemonset-not-ready` is critical only when Falco is not ready on a **Ready** node (bigpc powered off does not page); `falco-critical-events` fires immediately on any Critical/Error event; `falco-warning-events` requires a warning to recur for 30 minutes; `falco-event-drops` warns when the kernel-side drop counter moves; `falco-metrics-missing` warns when Prometheus cannot scrape either target. The known false alarms are excepted in `custom-rules.yaml`; the warning gate keeps one-off app noise off the phone.

## Runtime security (Falco)

- Falco (`targets/srv0/k3s-base/templates/falco.yaml`, chart 9.2.1 / Falco 0.45.1) runs as a DaemonSet on srv0 and bigpc with the modern eBPF driver. `collectors.kubernetes` is off; the container plugin uses `/run/k3s/containerd/containerd.sock` for `k8s.ns.name`/`k8s.pod.name`. Rules and the container plugin are installed by `falcoctl` at pod start; `follow` is disabled, so updates ride Renovate chart bumps.
- Events are JSON on stdout and Alloy's pod-log collector ships them to Loki. The provisioned **Falco** folder has two dashboards: **Falco Overview** (event stats, rate by priority/node, top rules, recent events with filters) and **Falco Health** (DaemonSet/scrape status, drops, CPU/memory, rule counts). For ad-hoc work, `{namespace="base", app="falco"} | json` remains available in Explore; metrics (`falcosecurity_*`) are scraped from the `falco-metrics` Service via the chart's ServiceMonitor (`job="falco-metrics"`).
- Rule tuning: `priority: notice` keeps the useful default rules. Known-noise suppressions live in `targets/srv0/k3s-base/files/falco/custom-rules.yaml` (mounted via `customRules`); the first pass covers the host-game PTRACE, FlareSolverr chromedriver, Immich pg_isready, logtfy, controller/job API calls, FreshRSS cron, Home Assistant packet sockets, Renovate's containerbase Node tool, and host dnf5 log rotation. More exceptions are added as the counts come in. False-alarm triage is available as the `falco-exception-triage` skill: it queries Loki for a time range/app, proposes scoped exceptions, applies them with consent, and verifies true positives. The `Contact K8S API Server From Container` output override deliberately drops `command=%proc.cmdline` (command lines can carry bearer tokens) and excludes `logtfy`, which watches pod logs through the API by design.
- Troubleshooting: no events → confirm the engine is `modern_bpf` in the pod log, then check SELinux (`ausearch -m avc -ts recent | grep -i falco`) and kernel lockdown; missing pod/namespace fields → check the K3s containerd socket mount; event drops (`falcosecurity_scap_n_drops_total`) → raise `driver.modernEbpf.bufSizePreset`; no metrics → check the chart's ServiceMonitor and the `allow-falco-metrics-ingress` NetworkPolicy.
- Fallback: if the least-privileged capability set cannot start on a node, set `driver.modernEbpf.leastPrivileged: false` (privileged). Do not switch to the kmod driver; Fedora kernel updates would require new headers.

## Manual first-time setup

One-time web-UI steps for apps with no API seeding:

- **radarr / sonarr** (`https://radarr.$SERVICES_DOMAIN`, `https://sonarr.$SERVICES_DOMAIN`, Authelia-protected): General → Authentication → Forms (create the admin account); Media Management → Root Folders (`/data/Movies` for radarr, `/data/TV` for sonarr); Download Clients → qBittorrent at `qbittorrent.apps.svc.cluster.local:8080` (credentials from the qBittorrent setup); Indexers via Prowlarr or manual; Connect → Jellyfin (`http://jellyfin.apps.svc.cluster.local:8096`, API key from the Jellyfin dashboard, notify On Import/On Upgrade). The arr API keys come pre-configured — read them with `kubectl -n apps get secret radarr-secret|sonarr-secret`.
- **prowlarr** (`https://prowlarr.$SERVICES_DOMAIN`): under Settings → Apps, register Radarr (`http://radarr.apps.svc.cluster.local:7878`) and Sonarr (`http://sonarr.apps.svc.cluster.local:8989`) using the keys from their secrets; Settings → Indexers then syncs both. Add FlareSolverr (`http://flaresolverr.apps.svc.cluster.local:8191`) for Cloudflare-protected indexers.
- **seerr** (`https://seerr.$SERVICES_DOMAIN`): log in with the Jellyfin account (`http://jellyfin.apps.svc.cluster.local:8096`), then under Settings → Services add Jellyfin, Radarr, and Sonarr (same URLs/keys as above).
- **FileBrowser** (`https://files.$SERVICES_DOMAIN`, VPN/LAN): no seeding — the first OIDC login creates the user, and members of Authelia's `admins` group get admin rights over the mounted Main tree.
- **Frigate ↔ Home Assistant**: add the MQTT integration once (`broker: mosquitto`, `port: 1883`, `user: homeassistant`, password = `HA_MQTT_PASSWORD` from `config/srv0/values.yaml`), then add the Frigate integration (`URL: http://frigate:5000`, the internal unauthenticated port). MQTT discovery creates the camera/event entities automatically, and the dashboard is provisioned for you (core cards only — no custom components; the Advanced Camera Card comes from the HA `integration-update` init container at `/local/community/advanced-camera-card-2026/dist/...`). Recordings go to NFS under `$SECONDARY_STORAGE_PATH/frigate`. Watch out: the Frigate UI can't be iframed (Authelia sends `X-Frame-Options: DENY`); the HA companion app can cache an old frontend (clear its storage); and deleting the rpi go2rtc password file means updating `FRIGATE_RTSP_PASSWORD` in `config/srv0/values.yaml` and re-applying frigate.
- **crowdsec-web-ui** (srv0 + vps0, once): register the LAPI machine using the `CROWDSEC_WEBUI_LAPI_PASSWORD` value, then create the first admin in the UI (`https://crowdsec.$SERVICES_DOMAIN` / `https://crowdsec.$CLOUD_SERVICES_DOMAIN`). On srv0, during an unlock: `kubectl -n base exec deploy/crowdsec-lapi -- cscli machines add crowdsec-web-ui --password '<value>' -f /dev/null`. On vps0: `docker exec crowdsec cscli machines add crowdsec-web-ui --password '<value>' -f /dev/null`. The registration lives in the LAPI DB (`crowdsec-pvc` / `compose_live_state/crowdsec/data`), and the app keeps retrying bootstrap in the background, so order doesn't matter.

## Updates (Renovate)

Renovate runs as one K3s CronJob on srv0 (base, `targets/srv0/k3s-base/templates/renovate.yaml`), `renovate-daily`, at 16:00 America/Toronto. `scripts/renovate-daily.sh` runs, in order: a derived-only Infra pass for `nfs-server-src` (so the rebuilt nfs-server digest exists before the main pass), the app/ops repos, a job-side merge of the derived-image PR once its checks pass, a wait for the app/derived GitHub Actions publishes to settle, the full Infra pass (which pins the new digests the same day), then notifications. The job uses the full `renovate/renovate` image (digest-pinned; ships the Go toolchain, though the repo no longer has a `go.mod`). It mounts only `{{ INFRA_ROOT }}/config/VARS.env`, `{{ INFRA_ROOT }}/.git/config`, and `scripts/` (read-only). The script sources `RENOVATE_GITHUB_TOKEN`, builds `RENOVATE_HOST_RULES` from the Docker Hub credentials, sets the repo-local git author, and runs Renovate twice (`RENOVATE_INCLUDE_PATHS` limits the first pass to the nfs source, and `RENOVATE_PRUNE_STALE_BRANCHES=false` stops it from autoclosing unrelated open PRs). `startingDeadlineSeconds`/`activeDeadlineSeconds` keep a hung run from blocking the next day. The repo lists live in `scripts/repos.sh`. `bash scripts/renovate.sh [apps|infra|all|clear-cache] [--dry-run]` remains the manual equivalent for other machines (needs Node/npm; opens PRs directly on GitHub); the scheduled routine is `scripts/renovate-daily.sh`. The manual runner caps Renovate's Docker Hub tag-list cache at 7 days via `RENOVATE_CACHE_TTL_OVERRIDE` (the Docker datasource otherwise keeps it for 90), and `clear-cache` wipes the persistent package cache when a digest update looks backwards.

Credentials: `RENOVATE_GITHUB_TOKEN` should be a fine-grained PAT or GitHub App installation token scoped to the app/ops repos plus `ImranR98/Infra` with Contents, Pull requests, Issues, and Workflows read/write plus Metadata, Actions, Checks, and Commit statuses read. `DOCKERHUB_USER`/`DOCKERHUB_TOKEN` in `config/VARS.env` are only used for Renovate's Docker Hub lookups; keep the token read-only. App image workflows and the NFS image workflow push to GHCR with the workflow `GITHUB_TOKEN` (`packages: write`), so they need no Docker Hub credentials; the former `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` Actions secrets were removed.

The daily run publishes a notification per PR it opened or refreshed: `scripts/renovate-notify.sh` queries the GitHub API for open `deps`-labeled PRs created or updated after the run start and posts each to ntfy topic `srv0_services_renovate` (the run is the only actor touching these PRs, so an update means the run reopened it or force-pushed new content). At the end of the run, `scripts/ci-notify.sh` posts one digest for failed app/Infra GitHub Actions runs from the last 24 hours and failed `test` checks on open Renovate PRs (the newest run wins, so a rerun clears an older failure). A Renovate failure, a derived-PR merge timeout, or a publish-wait timeout posts an ntfy failure message. The CronJob mounts `scripts/` read-only, gets `NTFY_URL`/`NTFY_TOPIC` from its env and the write token from the `renovate-ntfy-token` Secret, and its `app: renovate` pod label is admitted by ntfy's `allow-notification-ingress` policy; `renovate.sh` reads the ntfy settings from `config/srv0/values.yaml`. A notifier failure logs a warning without changing Renovate's exit code.

Infra PRs are manual: `git fetch origin pull/<n>/head:renovate/pr-<n>`, `git checkout renovate/pr-<n>`, run `bash scripts/validate.sh <target>`, merge locally, then `git push origin master`. Never merge in the platform UI — origin remains the source of truth. Renovate rebases its own open PRs and closes them automatically once `master` contains the change (on its next run). App-repo PRs are not merged here: each app repo has its own auto-merge policy (DSCPLN auto-merges all update types; the others auto-merge non-major/digest and major updates, leaving lockfile maintenance for review) and, on the public repos, a required `test` check.

**Automerge is off** in Infra `renovate.json` (`automerge: false` globally), so every Infra PR waits for a human (patch/minor and the grouped docker-digests batch included) — except the nfs-server derived-image PR, which the daily job merges itself once its PR image test passes. The app repos have their own auto-merge policy (DSCPLN auto-merges all update types; the others auto-merge non-major/digest and major updates, leaving lockfile maintenance for review); their publish workflows gate on `test`. Public app repos use GitHub's required `test` check + platform auto-merge; the private repos (`our-times`, `order-manager`, `moving-sale-2027`) use `platformAutomerge: false` because branch protection needs GitHub Pro on private repos, so Renovate merges its own PRs after the checks pass. Merging Infra only deploys the next time the deploy commands run (`docker compose up -d` / `helm upgrade --install`).

**Watchtower vs Renovate** — only pc/bigpc run watchtower, and it updates any local container lacking `com.centurylinklabs.watchtower.enable=false` — effectively just compose `syncthing/syncthing` (left untagged; socket-proxy carries the false label). Renovate's docker-compose manager skips `syncthing/syncthing`, which leaves the srv0 K3s syncthing (pinned tag) under Renovate. Everything else belongs to Renovate (srv0/vps0/rpi run no watchtower). Watchtower's own image is digest-pinned by Renovate (`nickfedor/watchtower:latest`) because it never updates itself.

`renovate.json` (repo root): the built-in managers cover **kubernetes** (`managerFilePatterns: /^targets\/srv0\/k3s-(base|apps)\/.*\.ya?ml$/` — plain pod-spec images, hook Jobs, and vendored system-upgrade manifests), **docker-compose** (every compose image), and **dockerfile** (the nfs Alpine base). The geoip Dockerfile/gomod and header-gate plugin are gone. Regex managers add: (1) k3s chart images (`valuesContent` repository/tag pairs and single-line refs; `currentDigest` is captured so pinned images refresh rather than re-pin), (2) HelmChart CR versions (`oci://` through the docker datasource, since the helm datasource can't do OCI, or `chart:`+`repo:`+`version:`), (3) K3s plan versions (`github-releases` on `k3s-io/k3s` with custom versioning), (4) Traefik plugin pins in `additionalArguments` (vps0 compose too), (5) immich-machine-learning (`github-releases`, `-openvino` suffix preserved), (6) the HA Frigate integration + Advanced Camera Card pins, (7) dotdc Grafana dashboard URLs in the k8s-monitoring values, (8) the Task Runner image in `targets/srv0/k3s-apps/templates/backupctl.yaml`, (9) `HELM_VERSION` in `scripts/prereqs.sh`. The runner script, not the repo config, supplies global options (token, repo). packageRules: floating `latest|stable|release|alpine` tags (plus every untagged compose image, which effectively carries `:latest`) get pinned to digests and all pins/refreshes are grouped into one PR (prHourlyLimit 20); majors are blocked for `postgres`, `clickhouse/clickhouse-server`, `fedora`, and `helm/helm`; syncthing (compose side; watchtower owns it on pc/bigpc) is disabled; the sale-site image (`ghcr.io/imranr98/moving-sale-2027`) is published from the private app repo to a public GHCR package and digest-refreshed in its own group; immich's postgres image uses custom regex versioning (only same-shape `18-vectorchordX.Y.Z-pgvectorA.B.C` tags, with the postgres major locked via the compatibility group). The D$CPLN `imranrdev/dscpln-*` images are digest-refreshed in a grouped PR (the monorepo build-time pin remains primary); the Authelia/Headlamp/Seerr chart images use `overridePackageName` to track their GHCR repositories. Nothing else is annotated — Renovate's default update decision applies.

App repos `ImranR98/PixelNtfy`, `ImranR98/ISBN-Lookup`, `ImranR98/apps.obtainium.imranr.dev`, `ImranR98/our-times`, `ImranR98/order-manager`, `ImranR98/Logtfy`, `ImranR98/moving-sale-2027`, and `ImranR98/opencode-sandbox` are in the Renovate runner and notifier lists. All app images are public, so vps0 pulls without registry auth and Renovate needs no `read:packages`; each image has its own digest group where it needs one. The runner also includes `ImranR98/dscpln-config` and `ImranR98/DSCPLN`; D$CPLN is public, its CI publishes the `dscpln-*` images on `main` after tests, and Renovate refreshes the Infra deployment digests.

Artifacts: all app images — the six apps, D$CPLN, `moving-sale-2027`, and `opencode-sandbox` — are built and published by their own repo CI; Infra only pins/refreshes their digests. Every app publish job pushes an immutable `:sha-<commit>` candidate, verifies the pulled digest, then promotes `:latest`, so a failed verification never moves `:latest`. The NFS server image (`ghcr.io/imranr98/nfs-server`) stays in this repo: `.github/workflows/nfs-server-image.yml` builds it on `nfs-server-src` changes, verifies the candidate digest, promotes `:latest`, and the daily Renovate job pins the new digest the same day. `nfs-server-src/build.sh` remains the local/emergency path. It installs the latest `nfs-utils` and Alpine packages for its pinned base. No app image is built manually; `opencode-sandbox`'s `build.sh` is its local/emergency path.

Post-update: `git diff` → `bash scripts/validate.sh <target>` → deploy.

## CI

`.github/workflows/validate.yml` runs on every push/PR: shellcheck, yamllint, helm lint/template with the committed `config_template` as a non-secret values overlay, `renovate-config-validator`, actionlint, and `git diff --check`. The full `validate.sh` remains the local review gate because it needs the filled `config/` tree. `.github/workflows/nfs-server-image.yml` builds the NFS image on `nfs-server-src` changes, verifies the candidate digest, then promotes `:latest`; it opens no PR and has no schedule. The app repos carry their own CI workflow (test, then candidate → verify → promote publish on the default branch); `opencode-sandbox` is one of them. Renovate's daily run pins the new digests.

The app publish steps and the NFS image workflow emit SBOM and provenance attestations (`sbom: true`, `provenance: true`).

## Host security updates

- **vps0 (Ubuntu 24.04):** `unattended-upgrades` is enabled and active.
- **srv0 / bigpc (Fedora 44, DNF5):** `dnf5-plugin-automatic` is not installed. To enable security-only updates without automatic reboots:

  ```bash
  sudo dnf install -y dnf5-plugin-automatic
  sudoedit /etc/dnf/automatic.conf
  # [commands]
  # upgrade_type = security
  # apply_updates = yes
  # download_updates = yes
  # reboot = never
  sudo systemctl enable --now dnf5-automatic.timer
  sudo systemctl list-timers dnf5-automatic.timer
  ```

  Then check `dnf5 needs-restarting -r` (or `needs-restarting -r`) periodically and reboot in a maintenance window; srv0's LUKS/K3s boot needs the normal unlock flow.

## Environment variables

Available to bash scripts: `$INFRA_ROOT` (repo root — self-computed by `scripts/common.sh` unless pre-set, so the in-cluster pods' values win), `$TARGET` (set by `require_target`/`require_target_host`), `$COMPOSE_STATE_DIR` (`current_target/compose_live_state`), `$STATE_BACKUP_DIR` (`state_backups`; `restic-restore.sh`), `$MY_UID` (current UID, forced to 1000 when root).
