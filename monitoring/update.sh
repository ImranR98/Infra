#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
bash "$HERE"/install.sh
kubectl -n production rollout restart deployment grafana
kubectl -n production delete pod "$(kubectl -n production get pod | grep prometheus | awk '{print $1}' | tail -1)"
kubectl -n production rollout restart daemonset loki-canary
kubectl -n production rollout restart statefulset loki loki-chunks-cache loki-results-cache
kubectl -n production delete pod "$(kubectl -n production get pod | grep loki-gateway | awk '{print $1}' | tail -1)"
kubectl -n production rollout restart daemonset promtail-daemonset