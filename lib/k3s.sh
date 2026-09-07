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
