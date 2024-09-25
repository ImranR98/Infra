#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
bash "$HERE"/install.sh
kubectl -n production rollout restart deployment crowdsec-lapi 
kubectl -n production rollout restart daemonset crowdsec-agent
echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."