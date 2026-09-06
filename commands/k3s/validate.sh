#!/bin/bash
# DESC: Validate Ansible provisioning playbooks (syntax + lint; never touches hosts)
set -euo pipefail
[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"

OPS_ANSIBLE="$INFRA_ROOT/ops/ansible"
export ANSIBLE_CONFIG="$OPS_ANSIBLE/ansible.cfg"
failed=0

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Error: ansible-playbook not found. Install ansible-core first." >&2
    exit 1
fi

for playbook in "$OPS_ANSIBLE"/playbooks/*.yml; do
    echo "==> Syntax check: ${playbook#"$INFRA_ROOT"/}"
    if ! ansible-playbook --syntax-check -i localhost, "$playbook"; then
        failed=1
    fi
done

if command -v yamllint >/dev/null 2>&1; then
    echo "==> yamllint: ops/ansible"
    if ! yamllint -c "$OPS_ANSIBLE/.yamllint" "$OPS_ANSIBLE"; then
        failed=1
    fi
else
    echo "Note: yamllint not installed; skipping YAML lint."
fi

if command -v ansible-lint >/dev/null 2>&1; then
    echo "==> ansible-lint: ops/ansible"
    if ! ansible-lint -c "$OPS_ANSIBLE/.ansible-lint" --offline "$OPS_ANSIBLE"; then
        failed=1
    fi
else
    echo "Note: ansible-lint not installed; skipping."
fi

exit "$failed"
