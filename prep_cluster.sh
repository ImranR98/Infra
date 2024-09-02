#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

kubectl create namespace production
kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
mkdir -p "$HERE"/state
