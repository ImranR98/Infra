#!/bin/bash
# DESC: Install system prerequisites via Ansible (bootstraps ansible-core first if needed)
set -euo pipefail
[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$INFRA_ROOT/lib/pkg.sh"

# The one imperative bootstrap step: ansible-core itself, via the system
# package manager. Everything else is declarative (ops/ansible/playbooks/prereqs.yml).
if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ansible-core not found — installing it to run the prereqs playbook..."
    SU="$(get_sudo_cmd)"
    case "$(detect_pkgmgr)" in
        apt) "$SU" bash -c 'apt-get update -qq && apt-get install -y ansible-core' ;;
        dnf) "$SU" bash -c 'dnf install -y ansible-core' ;;
        *)
            echo "Error: unsupported package manager. Install ansible-core manually." >&2
            exit 1
            ;;
    esac
fi

export ANSIBLE_CONFIG="$INFRA_ROOT/ops/ansible/ansible.cfg"
exec ansible-playbook -i localhost, "$INFRA_ROOT/ops/ansible/playbooks/prereqs.yml" "$@"
