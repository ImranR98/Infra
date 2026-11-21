# Operations

Day-to-day tasks: first boot, deploy, verify, update, back up, and maintain.

## First boot

Run on each machine:

```bash
bash scripts/prereqs.sh
bash scripts/init-config.sh srv0 --detect   # vps0/bigpc: omit --detect
```

Fill `config/<target>/` from its `config_template/` (see
[Configuration](configuration.md)). Then validate:

```bash
bash scripts/validate.sh srv0
bash scripts/validate.sh vps0
```

## Deploy

### srv0 — K3s

The admin kubeconfig is root-only. Open a session in one terminal:

```bash
bash scripts/kubeconfig-unlock.sh
```

In another terminal:

```bash
bash scripts/validate.sh srv0

helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml \
  --dependency-update

helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml --dependency-update
```

Apply `base` before `apps`; delete in reverse order. Both releases build their chart
dependencies into the gitignored `charts/` directory; `validate.sh` does this, and
`--dependency-update` covers direct Helm runs.

### Compose targets

Run from the repo root, on the target, with sudo:

```bash
# vps0
sudo docker compose \
  --env-file config/vps0/compose.env \
  -f targets/vps0/compose/compose.yaml \
  -f targets/vps0/compose/compose.private.yaml \
  --env-file targets/vps0/compose/.env \
  up -d --remove-orphans

# bigpc
sudo docker compose \
  --env-file config/bigpc/compose.env \
  -f targets/bigpc/compose/compose.yaml \
  --env-file targets/bigpc/compose/.env \
  up -d

# pc / rpi (no config env)
sudo docker compose \
  -f targets/pc/compose/compose.yaml \
  --env-file targets/pc/compose/.env \
  up -d
```

`srv0`'s public-exposure sidecar:

```bash
sudo docker compose \
  --env-file config/srv0/compose.env \
  -f targets/srv0/compose/compose.yaml \
  --env-file targets/srv0/compose/.env \
  up -d
```

Repeat the same flags for `ps`, `logs -f`, `down`, and `up -d <service>`.

### Verify

`helm upgrade` returning success is not enough; the `HelmChart` CRs install
asynchronously.

```bash
kubectl -n base get helmcharts
kubectl -n apps get helmcharts
for ns in base apps; do
  kubectl -n "$ns" get deploy,statefulset,daemonset -o name |
    while read -r r; do kubectl -n "$ns" rollout status "$r" --timeout=120s || echo "FAILED: $r"; done
done
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "pods OK"
kubectl get --raw /readyz
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
```

## Updates

Renovate runs as the six-hourly `renovate-daily` CronJob in `base`. App repos extend
`renovate-preset.json`; non-major app updates auto-merge after the `test` check, while
majors wait on the Dependency Dashboard. Infra PRs are never auto-merged; review,
validate, merge, then deploy.

- On-demand Infra run: `bash scripts/renovate.sh infra` (uses the token in
  `config/srv0/values.yaml`).
- Image refs use immutable tags and digests; channel-only images are digest-pinned on
  the allowlist shared by `renovate.json`, `renovate-preset.json`, and
  `scripts/check-images.sh`. Never hand-pin an app digest.
- After a Compose deploy that replaced an image, prune old images:
  `sudo docker image prune -af --filter until=336h`. The vps0
  `docker-image-prune.timer` does this monthly; Kubernetes uses kubelet GC.
- K3s upgrades are handled by the `system-upgrade-controller` Plans in
  `targets/srv0/k3s-base/templates/system-upgrade.yaml`; treat a Plan bump as a
  maintenance-window change and verify the HelmChartConfig customizations afterward.

See the `renovate-pr-ops` skill for the full PR/deploy workflow.

## Backups

D4TA runs the scheduled backup task and keeps the newest two snapshots under
`state_backups/snapshots/<UTC timestamp>/` (`latest` points at the newest). Snapshots
contain `app-data`, `db-dumps`, `compose`, and a manifest. The `auto-backup`/
`backup.infra/exclude` label mechanics are in
[Platform: storage](platform.md#storage).

```bash
bash scripts/state-restore.sh list
bash scripts/state-restore.sh restore [snapshot] [--live]
bash scripts/state-restore.sh db <ns/pvc> [snapshot]
bash scripts/state-restore.sh compose srv0|vps0 [snapshot] [--live]
```

`restore` and `compose` stage by default; `--live` replaces data and may require root.
`restore --live` expects the apps stopped. `compose vps0` uses `VPS0_HOST` (defaults to
`PUBLIC_EXPOSURE_HOST` from `config/srv0/compose.env`) and `SSH_KEY_FILE`
(defaults to `~/.ssh/id_ed25519`); override them explicitly when needed. Syncthing
replicates selected data between `srv0`, `pc`, and `bigpc`.

## Maintenance

- **Node IP change**: `sudo bash scripts/update-node-ip.sh [--ip X] [--force]`.
  It updates the K3s node-ip config, etcd member peer URLs, flannel annotation, and
  waits for the cluster.
- **LUKS preboot**: `bash scripts/preboot.sh public-exposure|crypt-ssh` installs the
  initramfs unlock module. `public-exposure` uses the `pre0` tunnel key; `crypt-ssh`
  opens dropbear on the LAN.
- **Public-exposure keys**: `bash scripts/public-exposure-keygen.sh [--force]` on
  srv0. `--force` invalidates every client profile.
- **Remote-access clients**: `bash scripts/remote-access-client.sh <client>` on an
  unlocked host.
- **vps0 Authelia**: edit `config/vps0/authelia/` then run
  `bash scripts/render-vps0-authelia.sh` before deploying.
- **NFS changes**: static PVs are immutable. Changing a `share` requires stopping the
  consuming app, deleting/recreating the PV/PVC, and re-deploying; data lives on the
  host paths. Test subdirectory mounts from the CSI node pod before switching.
- **Certificates**: `edge-public-tls`/`edge-private-tls` are re-issued on the next
  `srv0-base` deploy after `PUBLIC_HOSTS`/`PRIVATE_HOSTS` changes.
- **Docker cleanup**: keep `targets/vps0/docker-prune` installed on vps0; pinned
  digests leave old images behind.

## Scripts

| Script | Where | Purpose |
|---|---|---|
| `prereqs.sh` | any machine | Packages, Helm, Docker, machine-fact `.env`, state dirs |
| `init-config.sh` | any machine | Copy config templates; `--detect` sets srv0 `MY_UID` |
| `validate.sh` | any machine | Deploy preflight; host-gated checks on the target |
| `kubeconfig-unlock.sh` | srv0 | Temporary dev kubeconfig; root-only admin config stays 0600 |
| `k3s-server.sh` / `k3s-join.sh` | node | Provision/replace K3s nodes |
| `k3s-node-prep.sh` | node | Sysctls/firewall; called by the K3s scripts |
| `update-node-ip.sh` | srv0 | Node-IP/etcd/flannel update |
| `preboot.sh` | srv0 | Initramfs LUKS unlock |
| `public-exposure-keygen.sh` | srv0 | Tunnel keys + confs |
| `remote-access-client.sh` | unlocked host | Fetch an AmneziaWG client profile |
| `mtu-watch.sh` | tunnel containers | Path-MTU watcher |
| `renovate.sh` | any machine | On-demand Renovate run |
| `repos.sh` | any machine | Repo list from `config/srv0/values.yaml` |
| `state-restore.sh` | srv0 | List/stage/restore backups |
| `check-images.sh` | any machine | Image pinning policy |
| `test-device-plugin.sh` | CI | Device-plugin fixtures |
