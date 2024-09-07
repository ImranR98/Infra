#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade --namespace production crowdsec crowdsec/crowdsec --values "$HERE"/values.yaml
bash "$HERE"/other/selinux_workaround.sh
kubectl -n production rollout restart deployment crowdsec-lapi 
kubectl -n production rollout restart daemonset crowdsec-agent
echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."