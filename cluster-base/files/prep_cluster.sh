#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

kubectl create namespace production
kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" main-storage=true # Assume the control plane node is also the main-storage node
kubectl label nodes "$(hostname | tr "[:upper:]" "[:lower:]")" entrypoint=true # Assume the control plane node is also the FRPC node
kubectl apply -f "$HERE"/admin-user.yaml # Mainly for K8s dashboard but could be used for anything so it is put here instead of in that component 
mkdir -p "$HERE"/state
