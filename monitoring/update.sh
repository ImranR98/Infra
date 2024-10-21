#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HELPERS_PATH"

bash "$HERE"/install.sh
kubectl -n production rollout restart deployment grafana
deletePodsByGrep prometheus
kubectl -n production rollout restart daemonset loki-canary
kubectl -n production rollout restart statefulset loki loki-chunks-cache loki-results-cache
deletePodsByGrep loki-gateway
kubectl -n production rollout restart daemonset promtail-daemonset