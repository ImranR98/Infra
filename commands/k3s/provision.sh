#!/bin/bash
# DESC: Bootstrap a K3s control plane (no args; run on the node) or join a node (run on the control plane)
set -euo pipefail
[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$INFRA_ROOT/lib/common.sh"

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Error: ansible-playbook not found. Run 'task prereqs' on the control host first." >&2
    exit 1
fi

export ANSIBLE_CONFIG="$INFRA_ROOT/ops/ansible/ansible.cfg"

amdgpu_mode="auto"
discouraged=false
longhorn=false
check_mode=""
diff_mode=""
extra_vars=()
ip=""
user=""
role=""

while [ $# -gt 0 ]; do
    case "$1" in
        --amdgpu)
            amdgpu_mode="${2:?Error: --amdgpu requires auto|yes|no}"
            case "$amdgpu_mode" in auto|yes|no) ;; *) echo "Error: --amdgpu must be one of auto|yes|no" >&2; exit 1 ;; esac
            shift
            ;;
        --scheduling-discouraged) discouraged=true ;;
        --longhorn) longhorn=true ;;
        --check) check_mode=1 ;;
        --diff) diff_mode=1 ;;
        -e|--extra-vars)
            extra_vars+=(-e "$2")
            shift
            ;;
        -*)
            echo "Error: unknown flag '$1'" >&2
            echo "Usage: $0 [<ip> <user> [agent|server]] [--amdgpu auto|yes|no] [--scheduling-discouraged] [--longhorn] [--check] [--diff] [-e key=value]" >&2
            exit 1
            ;;
        *)
            if [ -z "$ip" ]; then
                ip="$1"
            elif [ -z "$user" ]; then
                user="$1"
            elif [ -z "$role" ]; then
                role="$1"
            else
                echo "Error: too many positional arguments" >&2
                exit 1
            fi
            ;;
    esac
    shift
done

play_args=()
[ -n "$check_mode" ] && play_args+=(--check)
[ -n "$diff_mode" ] && play_args+=(--diff)

# No positional args: bootstrap THIS node as the control plane (cluster-init).
if [ -z "$ip" ]; then
    echo "Provisioning this node ($(hostname)) as the K3s control plane..."
    exec ansible-playbook -i localhost, "$INFRA_ROOT/ops/ansible/playbooks/k3s_server.yml" \
        "${play_args[@]}" "${extra_vars[@]}"
fi

# Otherwise: join a remote node. Requires a control plane on this machine.
if [ -z "$user" ]; then
    echo "Error: <user> is required (got only IP '$ip')" >&2
    exit 1
fi
[ -z "$role" ] && role="agent"
case "$role" in agent|server) ;; *) echo "Usage: $0 <ip> <user> [agent|server]" >&2; exit 1 ;; esac

if ! printf '%s' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "Error: <ip> must be an IPv4 address (got '$ip')" >&2
    exit 1
fi
if [ -z "$user" ] || [[ "$user" =~ [^a-zA-Z0-9_-] ]] || [ "${user:0:1}" = "-" ]; then
    echo "Error: <user> contains invalid characters" >&2
    exit 1
fi

inventory_file=$(mktemp /tmp/infra-k3s-inventory.XXXXXX.yaml)
trap 'rm -f "$inventory_file"' EXIT
cat > "$inventory_file" <<EOF
all:
  hosts:
    server:
      ansible_connection: local
    node:
      ansible_host: "$ip"
      ansible_user: "$user"
EOF
chmod 600 "$inventory_file"

join_vars=(-e "k3s_role=$role" -e "k3s_join_ip=$ip" -e "k3s_joined=true" -e "k3s_amdgpu_mode=$amdgpu_mode")
if [ "$discouraged" = true ]; then
    join_vars+=(-e k3s_scheduling_discouraged=true)
fi
if [ "$longhorn" = true ]; then
    join_vars+=(-e k3s_longhorn_replicas=true)
fi

echo "Joining $ip ($user) to the cluster as '$role'..."
ansible-playbook -i "$inventory_file" "$INFRA_ROOT/ops/ansible/playbooks/k3s_join.yml" \
    "${play_args[@]}" "${join_vars[@]}" "${extra_vars[@]}"
