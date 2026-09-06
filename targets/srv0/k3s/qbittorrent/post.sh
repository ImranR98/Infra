#!/bin/bash
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
# The linuxserver/qbittorrent image ignores QBT_WEBUI_PASSWORD — API calls
# are the only way to set credentials. The s6-overlay init system also means
# the pod must NOT set runAsUser/runAsGroup; use PUID/PGID env vars instead.

echo "=== qBittorrent Setup ==="
echo "Waiting for qBittorrent to be ready..."
kubectl -n apps wait --for=condition=ready pod -l app=qbittorrent --timeout=120s

for i in $(seq 1 10); do
    TMP_PASS=$(kubectl -n apps logs deploy/qbittorrent 2>&1 | grep -oP 'A temporary password is provided for this session: \K\S+' || true)
    [ -n "$TMP_PASS" ] && break
    sleep 2
done

if [ -n "$TMP_PASS" ]; then

  PASSWORD="adminadmin"

  echo "Setting permanent password and preferences via API..."
  # Credentials ride stdin (never argv — ps-visible on host), mirroring immich/post.sh.
  { printf '%s\n' "$TMP_PASS"; printf '%s\n' "$PASSWORD"; } | kubectl -n apps exec -i deploy/qbittorrent -- sh -c '
    set -e
    IFS= read -r tmp_pass
    IFS= read -r password
    curl -s -c /tmp/qbt-cookies -X POST -d "username=admin&password=$tmp_pass" http://localhost:8080/api/v2/auth/login > /dev/null

    curl -s -b /tmp/qbt-cookies -X POST \
      -d "json={\"listen_port\":56881,\"upnp\":false,\"save_path\":\"/data/downloads\",\"temp_path\":\"/data/downloads/incomplete/\",\"temp_path_enabled\":true,\"web_ui_password\":\"$password\"}" \
      http://localhost:8080/api/v2/app/setPreferences > /dev/null

    rm -f /tmp/qbt-cookies
  '

  echo "Password set to: $PASSWORD"
else
  echo "No temporary password found (config already exists, skipping API setup)."
fi

echo ""
echo "1. Access https://qbittorrent.${SERVICES_DOMAIN} (authenticate via Authelia)"
echo "2. Log in with username: admin  password: adminadmin"
echo "3. (Optional) Tools > Options > Downloads > Categories:"
echo "     radarr  /data/downloads/radarr"
echo "     sonarr  /data/downloads/sonarr"
echo ""
echo "Peer port 56881 is forwarded via FRP — check Tools > Options > Connection."
