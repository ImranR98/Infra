#!/bin/bash
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

echo "=== qBittorrent Setup ==="

TMP_PASS=$(kubectl -n apps logs deploy/qbittorrent 2>&1 | grep -oP 'A temporary password is provided for this session: \K\S+' || true)

if [ -n "$TMP_PASS" ]; then

  PASSWORD="adminadmin"

  echo "Setting permanent password and preferences via API..."
  kubectl -n apps exec deploy/qbittorrent -- sh -c "
    set -e
    SID=\$(curl -s -c /tmp/qbt-cookies -X POST -d 'username=admin&password=$TMP_PASS' http://localhost:8080/api/v2/auth/login 2>&1)

    curl -s -b /tmp/qbt-cookies -X POST -d 'password=$TMP_PASS&newPassword=$PASSWORD' \
      http://localhost:8080/api/v2/auth/changePassword > /dev/null

    curl -s -b /tmp/qbt-cookies -X POST \
      -d 'json={\"listen_port\":56881,\"upnp\":false,\"save_path\":\"/data/downloads\",\"temp_path\":\"/data/downloads/incomplete/\",\"temp_path_enabled\":true}' \
      http://localhost:8080/api/v2/app/setPreferences > /dev/null

    rm -f /tmp/qbt-cookies
  "

  echo "Password set to: $PASSWORD"
else
  echo "No temporary password found (config already exists, skipping API setup)."
fi

echo ""
echo "1. Access https://qbittorrent.${SERVICES_DOMAIN:-home.example.org} (authenticate via Authelia)"
echo "2. Log in with username: admin  password: adminadmin"
echo "3. (Optional) Tools > Options > Downloads > Categories:"
echo "     radarr  /data/downloads/radarr"
echo "     sonarr  /data/downloads/sonarr"
echo ""
echo "Peer port 56881 is forwarded via FRP — check Tools > Options > Connection."
