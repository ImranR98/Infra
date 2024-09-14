#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TEMP_SECRET_MANIFEST="$(mktemp)"
TEMP_FILE="$(mktemp)"
trap "rm "$TEMP_SECRET_MANIFEST"; rm "$TEMP_FILE"" EXIT
cat "$HERE"/users-database.yaml | envsubst > "$TEMP_SECRET_MANIFEST"
kubectl create -n production secret generic authelia-users --from-file="$TEMP_SECRET_MANIFEST"
sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/values.yaml >"$TEMP_FILE"
helm install authelia authelia/authelia --values <(cat "$TEMP_FILE" | envsubst) --namespace production
echo "NOTE: Some lines in authelia/values.yaml were commented out according to the \"IGNORE INITIALLY\" annotation.
      Run authelia/upgrade.sh to apply the original values.yaml (after ensuring it is okay to do so)."
echo 'NOTE: To get notification.txt from inside the container, run this:
      kubectl -n production exec --stdin --tty "$(kubectl -n production get pod | grep authelia | grep -v redis | grep -v postgres | awk '{print \$1}')" -- cat /config/notification.txt'