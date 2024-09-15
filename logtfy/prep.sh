#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

# Create service account
wget https://raw.githubusercontent.com/ImranR98/Logtfy/master/k8s/prep.sh -O "$HERE"/prepLogtfy.sh
wget https://raw.githubusercontent.com/ImranR98/Logtfy/master/k8s/role.yaml -O "$HERE"/role.yaml
if [ -d "$HERE"/logtfy.json ]; then
    rmdir "$HERE"/logtfy.json
fi
bash "$HERE"/prepLogtfy.sh production
rm "$HERE"/token
rm "$HERE"/ca.crt
rm "$HERE"/prepLogtfy.sh

# Create secret
cat "$HERE"/logtfy.template.json | envsubst >"$HERE"/logtfy.json
kubectl -n production get secret logtfy-config 2>/dev/null && kubectl -n production delete secret logtfy-config || :
kubectl create -n production secret generic logtfy-config --from-file="$HERE/logtfy.json"