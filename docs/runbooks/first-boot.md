# Runbook: first bootstrap

1. **DNS/edge first.** `$SERVICES_DOMAIN` → vps0; `home.$SERVICES_DOMAIN` + `*.home.$SERVICES_DOMAIN` are routed through the public-exposure tunnel. Generate the tunnel material on srv0 (`scripts/public-exposure-keygen.sh`) and copy `config/vps0/public-exposure/` to vps0. Bring vps0 up before srv0 — cert-manager's HTTP-01 challenges need the edge serving.
2. **Prereqs.** `bash scripts/prereqs.sh` on every machine.
3. **Config.** Copy each `targets/<t>/config_template` to `config/<t>/` and fill it; copy `config_template/VARS.env` to `config/VARS.env`.
4. **First-boot private apps.** In `config/srv0/values.yaml` set:
   ```yaml
   BOOTSTRAP_PRIVATE_APPS: "true"
   ```
   This keeps Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome and Opodsync on the `websecure` listener only (LAN/VPN).
5. **srv0.** `validate.sh srv0` → `k3s-server.sh` (sets the static node labels) → `kubeconfig-unlock.sh` → start the public-exposure client compose sidecar → `helm upgrade --install srv0-base ...` → `helm upgrade --install srv0-apps ...`.
6. **Reach the six apps over LAN/VPN.** Use the AmneziaWG VPN (its `remote-access-dns` resolves `*.$SERVICES_DOMAIN` to `10.100.0.1`) or a temporary `/etc/hosts` entry pointing the six hostnames at srv0's LAN IP. TLS certs still issue normally: the HTTP-01 solver uses the `web` entrypoint/Ingress on port 80, independent of the routes' listeners. Immich/Linkwarden OIDC works once Authelia is Ready.
7. **Authelia first.** Finish the Authelia/OIDC setup; then set `BOOTSTRAP_PRIVATE_APPS: "false"` in `config/srv0/values.yaml` and re-apply `srv0-apps`. `validate.sh srv0` warns while the flag is still true.
8. **Join nodes.** `k3s-join.sh <ip> <user>`; add `--hostpath-main` only for a node that owns the Main host paths, and `--scheduling-discouraged` for desktops.
9. **Post-deploy.** Follow the manual app seeding in `docs/operations.md` (radarr/sonarr/prowlarr/seerr/FileBrowser/Frigate HA/crowdsec-web-ui).
10. **Verify.** Jellyfin: `curl -sk https://tv.$SERVICES_DOMAIN/System/Info/Public`; `kubectl get pods -A`; `kubectl get pvc -A`; `bash scripts/validate.sh srv0`.
