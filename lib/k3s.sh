#!/bin/bash
# lib/k3s.sh — K3s cluster helpers. Node provisioning (installer, config,
# sysctl, firewall, joins) moved to Ansible: ops/ansible/roles/ + playbooks/.

wait_for_k3s_cluster() {
    local timeout_secs="${1:-150}"
    local max_tries=$(( timeout_secs / 5 ))
    for i in $(seq 1 "$max_tries"); do
        if kubectl get nodes >/dev/null 2>&1; then
            echo "Cluster ready."
            return 0
        fi
        echo "Waiting... ($i/$max_tries)"
        sleep 5
    done
    echo "Error: Could not connect to Kubernetes cluster after ${timeout_secs} seconds." >&2
    return 1
}

wait_for_crds() {
    local timeout_secs="${1:-300}"
    local max_tries=$(( timeout_secs / 15 ))
    shift
    local all_ok=true
    for crd in "$@"; do
        local crd_ok=false
        for _ in $(seq 1 "$max_tries"); do
            kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null && { crd_ok=true; break; }
            sleep 5
        done
        if [ "$crd_ok" = false ]; then
            echo "Error: CRD $crd not established after ${timeout_secs}s" >&2
            all_ok=false
        fi
    done
    $all_ok
}
