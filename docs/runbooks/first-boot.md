# Runbook: first bootstrap

This is the end-to-end path from a fresh clone to a working reference stack.
It assumes the five-machine topology (`srv0`, `vps0`, `pc`, `bigpc`, `rpi`).
Skip or remove targets/apps you do not use; see **Minimal stack** below.

The reference stack is a personal app catalog, not a blank starter. The
fastest successful install is usually to prune unused apps and SANs before
filling every reference secret.

## 0. Decide before building

Decide:

- target hostnames and LAN IPs
- public domains:
  - `BASE_SERVICES_DOMAIN`, e.g. `example.org`
  - `SERVICES_DOMAIN`, e.g. `home.example.org`
  - `CLOUD_SERVICES_DOMAIN`, e.g. `cloud.example.org`
- `DOMAIN_OWNER_EMAIL`
- which optional app groups you use: arr stack, Frigate/rpi, D$CPLN,
  Guacamole, ConBee/Bluetooth, GPU workloads
- `MAIN_PARENT_DIR` and `SECONDARY_STORAGE_PATH`
- whether srv0/bigpc use LUKS

Set hostnames before `prereqs.sh`; host-level scripts and Compose expect the
hostname to match the target directory:

```bash
sudo hostnamectl set-hostname srv0
# vps0, pc, bigpc, rpi similarly
```

## 1. DNS and vps0 edge

Point DNS at vps0 before deploying:

- `SERVICES_DOMAIN` and `*.$SERVICES_DOMAIN` — e.g. `home.example.org` and
  `*.home.example.org`
- `CLOUD_SERVICES_DOMAIN` and `*.$CLOUD_SERVICES_DOMAIN` — e.g.
  `cloud.example.org` and `*.cloud.example.org`
- any base-domain apps you keep, e.g. `example.org` / `*.example.org`

vps0's file provider routes `home.$BASE_SERVICES_DOMAIN` and
`*.home.$BASE_SERVICES_DOMAIN` over the public-exposure tunnel to srv0. When
`SERVICES_DOMAIN` is `home.$BASE_SERVICES_DOMAIN`, that is the same as
`$SERVICES_DOMAIN` and `*.$SERVICES_DOMAIN`; the Kubernetes apps are
`<app>.$SERVICES_DOMAIN`.

Open the vps0 firewall for:

- `80/tcp`, `443/tcp`
- `51822/udp` — public-exposure WireGuard hub
- `51820/udp` — AmneziaWG VPN DNAT
- `8887/tcp` — initramfs preboot SSH
- `56881/tcp` + `56881/udp` — qBittorrent, if used

The exact DNAT list is `targets/vps0/compose/files/public-exposure/forwards.conf`.

`PUBLIC_HOSTS` drives the exact TLS SAN list. Remove any hostname you do not
serve before the first srv0 deploy, or Let's Encrypt HTTP-01 can fail.

## 2. Clone and install prerequisites

On every machine:

```bash
git clone <your-Infra-repo> ~/Infra
cd ~/Infra
bash scripts/prereqs.sh
```

`prereqs.sh` installs `yq`, `jq`, `curl`, `openssl`, `git`, NFS utilities,
Node/npm, WireGuard tools, the pinned Helm binary, Docker/Compose, and writes
`targets/<hostname>/compose/.env`. It also creates Compose bind dirs and the
Traefik ACME seed.

Run prereqs on srv0 and vps0 before `init-config.sh`; `init-config` uses `yq`.

For srv0, confirm `MAIN_PARENT_DIR` exists with its `Main/` tree,
`SECONDARY_STORAGE_PATH` is mounted, and the LUKS/remote-unlock drivers are in
the initramfs.

## 3. Initialise the config trees

On srv0:

```bash
bash scripts/init-config.sh srv0 --detect
```

On vps0:

```bash
bash scripts/init-config.sh vps0
```

`init-config` copies templates without overwriting existing files. On srv0,
`--detect` sets `MY_UID`, `GPU_PROFILE`, `HA_CONBEE`, and `HA_BLUETOOTH` from
the current hardware. It does not generate passwords, hashes, or GitHub
tokens.

## 4. Fill configuration

### srv0: `config/srv0/values.yaml`

Required roots and first-boot values:

```yaml
SERVICES_DOMAIN: "home.example.org"
DOMAIN_OWNER_EMAIL: "you@example.org"
LAN_CIDR: "192.168.1.0/24"
MAIN_PARENT_DIR: "/home/you"
SECONDARY_STORAGE_PATH: "/mnt/k3s_extra_storage"
BOOTSTRAP_PRIVATE_APPS: "true"
```

Leave these empty to use derived defaults:

- `INFRA_ROOT`
- `MEDIA_DIR_PATH`
- `WA_TXT_PATH`
- `DSCPLN_LEDGER_PATH`
- `DSCPLN_CONFIG_PATH`
- `HOME_DIR`
- `JOURNAL_DIR`

Review the detected `MY_UID`, `GPU_PROFILE`, `HA_CONBEE`, and `HA_BLUETOOTH`.
Fill every reference app secret you keep. At minimum this includes Authelia,
Immich, Jellyfin, Grafana, MQTT/HA, and Frigate if used.

Prune `PUBLIC_HOSTS` and `PRIVATE_HOSTS` to the apps you actually serve. Add or
remove the corresponding app templates and HTTPRoutes.

If using Frigate, run step 6 now to generate the rpi password, then set
`FRIGATE_RTSP_PASSWORD` and the camera IP in `FRIGATE_ADDITIONAL_CONFIG`
before deploying srv0.

If using Guacamole, set `GUACAMOLE_WINDOWS_HOST`; follow
`docs/runbooks/windows-remote.md`.

If using D$CPLN, set `DSCPLN_CONFIG_PATH`, `DSCPLN_AGENTS`, and the Task Runner
settings, and make sure the private config checkout exists. Otherwise remove
the `dscpln-*` templates and Task Runner.

### srv0: `config/srv0/compose.env`

```dotenv
PUBLIC_EXPOSURE_HOST=vps0.example.org
PUBLIC_EXPOSURE_PORT=51822
```

`PUBLIC_EXPOSURE_HOST` must resolve before key generation.

### vps0: `config/vps0/compose.env`

Set `BASE_SERVICES_DOMAIN`, `CLOUD_SERVICES_DOMAIN`,
`DOMAIN_OWNER_EMAIL`, and the app secrets. Set
`COMPOSE_PROFILES=dscpln-agent` only if you use the vps0 archive agent.

### Authelia

There are two Authelia instances:

- srv0 users: `AUTHELIA_USERS_DATABASE` in `config/srv0/values.yaml`
- srv0 rules: `AUTHELIA_ACCESS_CONTROL_RULES` in the same file
- vps0 users: `config/vps0/authelia/users_database.yml`
- vps0 rules: `config/vps0/authelia/access_control.yml`

Generate Argon2 hashes with:

```bash
docker run -it authelia/authelia:latest authelia crypto hash generate argon2
```

Keep group names consistent across both user databases, both rules files,
`OPENWEBUI_*`, and `FILEBROWSER_ADMIN_GROUP`.

### Universal automation config

For Renovate/CI, fill `config/VARS.env`:

```dotenv
RENOVATE_GITHUB_TOKEN=...
INFRA_REPO=<owner>/Infra
APP_REPOS=<owner>/app1,<owner>/app2
DOCKERHUB_USER=...
DOCKERHUB_TOKEN=...
```

This is not needed for a minimal Helm deploy; `validate.sh` warns about
placeholders here.

## 5. Public-exposure keys and preboot

On srv0, after `config/srv0/compose.env` is filled:

```bash
bash scripts/public-exposure-keygen.sh
```

This writes the srv0 and vps0 public-exposure key material and the qBittorrent
tunnel keys in srv0 values. Copy the vps0 material:

```bash
scp -r config/vps0/public-exposure root@vps0:/root/Infra/config/vps0/
```

Do not hand-edit the generated files.

Install initramfs unlock:

```bash
# srv0, remote unlock through the public-exposure tunnel
bash scripts/preboot.sh public-exposure

# bigpc, LAN unlock if its root is LUKS-encrypted
bash scripts/preboot.sh crypt-ssh
```

Test a reboot before relying on remote unlock.

## 6. Bring up rpi first if using Frigate

Frigate needs the rpi go2rtc password before srv0 deploys. On rpi:

```bash
cd ~/Infra
bash scripts/prereqs.sh
bash scripts/deploy.sh rpi
cat current_target/compose_live_state/go2rtc/password
```

Put that value into srv0's `FRIGATE_RTSP_PASSWORD` and set the camera IP in
`FRIGATE_ADDITIONAL_CONFIG`. If you do not use the camera, remove Frigate,
the HA camera dashboard, and the rpi target.

## 7. Deploy vps0 first

On vps0:

```bash
cd /root/Infra
bash scripts/deploy.sh vps0
```

This renders vps0 Authelia, validates the config, and runs the standard
Compose wrapper. vps0 must be serving before srv0 can complete HTTP-01
certificate challenges.

Check:

```bash
docker compose ps
curl -I https://auth.$CLOUD_SERVICES_DOMAIN
```

## 8. Bootstrap srv0

On srv0:

```bash
cd /home/you/Main/Infra

# Only if using the Task Runner/D$CPLN. It creates Main dirs and checks the
# private config checkout.
bash scripts/preflight-task-runner.sh --fix

bash scripts/k3s-server.sh
```

In another terminal, hold kubeconfig access open:

```bash
bash scripts/kubeconfig-unlock.sh
```

Start the public-exposure client:

```bash
bash scripts/compose.sh srv0 up -d
```

Deploy the Kubernetes stack:

```bash
bash scripts/deploy.sh srv0
```

`deploy.sh` runs `validate.sh`, then `srv0-base`, `srv0-apps`, and rollout
checks. `BOOTSTRAP_PRIVATE_APPS` is still `true`, so Home Assistant, Immich,
Jellyfin, Linkwarden, Navidrome, and Opodsync are LAN/VPN-only.

## 9. Join bigpc and deploy the other targets

On srv0:

```bash
bash scripts/k3s-join.sh <bigpc-ip> <bigpc-user> \
  --role agent --scheduling-discouraged
```

Do not pass `--hostpath-main` to bigpc; that label is a singleton for srv0.

On bigpc:

```bash
cd ~/Infra
bash scripts/prereqs.sh
bash scripts/deploy.sh bigpc
```

On pc:

```bash
bash scripts/prereqs.sh
bash scripts/deploy.sh pc
```

On rpi (already initialized in step 6):

```bash
bash scripts/deploy.sh rpi
```

## 10. Finish Authelia, then open the six apps

1. Log in to srv0 and vps0 Authelia with the users you created.
2. Verify OIDC for Immich, Linkwarden, Grafana, and the rest.
3. Set:

```yaml
BOOTSTRAP_PRIVATE_APPS: "false"
```

4. Redeploy:

```bash
bash scripts/deploy.sh srv0
```

`validate.sh` warns while the flag is true.

## 11. First-boot app setup and access

Automatic/declarative:

- Immich admin seed — password in the `immich-seed-admin` Secret in `apps`
- qBittorrent config copy-once init
- Authelia users/rules

Manual steps are in `docs/operations.md` **Manual first-time setup**:

- Radarr/Sonarr/Prowlarr/Seerr
- FileBrowser first OIDC login
- Home Assistant MQTT + Frigate integration
- CrowdSec web UI LAPI registration
- Guacamole/Windows, if used

Generate VPN client profiles after the cluster is up:

```bash
bash scripts/remote-access-client.sh client1
```

Profiles land under `config/srv0/remote-access/`.

## 12. Verify

```bash
bash scripts/validate.sh srv0
bash scripts/validate.sh vps0

kubectl get nodes -o wide
kubectl get pods -A
kubectl get pvc -A

helm -n base list
helm -n apps list
```

Check:

- `https://auth.$SERVICES_DOMAIN`
- `https://tv.$SERVICES_DOMAIN/System/Info/Public`
- `https://immich.$SERVICES_DOMAIN`
- Frigate and Home Assistant
- vps0 `docker compose ps`
- `curl http://10.99.0.1:8788/healthz` if using the vps0 agent
- `bash scripts/restic-restore.sh list` if using state backups
- `bash scripts/renovate.sh --dry-run` if using Renovate

## Minimal stack

If you do not want the reference catalog:

- remove unused `targets/srv0/k3s-apps/templates/*.yaml` and their routes
- remove unused services from `targets/vps0/compose/compose.yaml`
- remove unused labels from `PUBLIC_HOSTS`/`PRIVATE_HOSTS`
- remove the rpi target and Frigate/HA camera dashboard if no camera
- remove `dscpln-*` templates and the Task Runner if no D$CPLN private repo
- leave `DSCPLN_AGENTS: {}` and the vps0 `COMPOSE_PROFILES` empty
- remove Guacamole if no Windows host
- set `OLLAMA_GPU=none` or remove Ollama if bigpc has no AMD GPU
- `init-config --detect` already sets no-GPU/no-ConBee/no-Bluetooth profiles

`DSCPLN_AGENTS: {}` only disables archive agents; it does not remove the
D$CPLN portal/balance/file-pipelines/task-runner apps.

## Common first-boot failures

| Symptom | Likely cause |
|---|---|
| `init-config` fails on `yq` | `prereqs.sh` was not run first |
| Compose says target mismatch | hostname is not `srv0`/`vps0`/`pc`/`bigpc`/`rpi` |
| vps0 cannot start the public-exposure hub | `config/vps0/public-exposure/pubexp-server0.conf` was not copied |
| cert-manager HTTP-01 fails | DNS/`PUBLIC_HOSTS` mismatch, vps0 down, or port 80 blocked |
| Frigate rejects the camera or password | rpi was not started or `FRIGATE_RTSP_PASSWORD` was not updated |
| Jellyfin/Frigate/Immich ML Pending | wrong `GPU_PROFILE` or missing device-plugin resource |
| Home Assistant Pending | `HA_CONBEE=true`/`HA_BLUETOOTH=true` with no hardware |
| Task Runner Pending | `DSCPLN_CONFIG_PATH` checkout missing |
| `deploy.sh` cannot reach the cluster | `kubeconfig-unlock.sh` is not running |
| apps remain LAN/VPN-only | `BOOTSTRAP_PRIVATE_APPS` is still `true` |
| `validate` prints VARS warnings | Renovate/CI config incomplete; not a deploy blocker |
| `validate` reports SAN/route drift | app template and `PUBLIC_HOSTS` disagree |
