#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

TEMP_CODE=0
(
    kubectl get nodes >/dev/null 2>&1
) || TEMP_CODE=$?
if [ "$TEMP_CODE" != 0 ]; then
    bash "$HERE"/files/install_k8s.sh master
    bash "$HERE"/files/prep_cluster.sh
    echo ""
else
    echo "Cluster already set up."
fi
