#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
kubectl -n production delete pod "$(kubectl -n production get pod | grep mosquitto | awk '{print $1}' | tail -1)" # 'rollout restart' causes conflict btn. instances