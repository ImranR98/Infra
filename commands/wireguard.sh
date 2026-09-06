#!/bin/bash
# DESC: Install WireGuard and deploy a config file (pass the .conf path after --)
set -euo pipefail
[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"

CONFIG_FILE="${1:?Usage: $0 <path-to-wireguard-conf>}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Error: ansible-playbook not found. Run task prereqs first." >&2
    exit 1
fi

export ANSIBLE_CONFIG="$INFRA_ROOT/ops/ansible/ansible.cfg"
CONFIG_ABS="$(readlink -f "$CONFIG_FILE")"
exec ansible-playbook -i localhost, "$INFRA_ROOT/ops/ansible/playbooks/wireguard.yml" \
    --extra-vars "wireguard_conf_src=$CONFIG_ABS"
