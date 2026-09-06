#!/bin/bash
# DESC: Update K3s node IP after a network change (Ansible wrapper)
set -euo pipefail
[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$INFRA_ROOT/lib/common.sh"

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Error: ansible-playbook not found. Run 'task prereqs' on the node first." >&2
    exit 1
fi

export ANSIBLE_CONFIG="$INFRA_ROOT/ops/ansible/ansible.cfg"
args_str="$*"
exec ansible-playbook -i localhost, "$INFRA_ROOT/ops/ansible/playbooks/k3s_update_node_ip.yml" \
    --extra-vars "infra_root=$INFRA_ROOT" \
    --extra-vars "target_name=${TARGET:-}" \
    --extra-vars "k3s_update_node_ip_args=$args_str"
