#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
kubectl create -n production secret generic authelia-users --from-file="$HERE"/users-database.yaml
TEMP_FILE="$(mktemp)"
trap "rm "$TEMP_FILE"" EXIT
sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/values.yaml >"$TEMP_FILE"
helm install authelia authelia/authelia --values "$TEMP_FILE" --namespace production
echo "NOTE: Some lines in authelia/values.yaml were commented out according to the \"IGNORE INITIALLY\" annotation.
      Run authelia/upgrade.sh to apply the original values.yaml (after ensuring it is okay to do so)."