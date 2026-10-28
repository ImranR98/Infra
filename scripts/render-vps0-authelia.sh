#!/bin/bash
# DESC: Render the vps0 Authelia configuration from the committed base file
# plus the deployment-specific access-control rules in
# config/vps0/authelia/access_control.yml. Run ON vps0 before `docker compose
# up`; --check renders to a temp file and fails if the live config is stale.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") [--check]"
    echo
    echo "Renders targets/vps0/compose/files/authelia/configuration.base.yml +"
    echo "config/vps0/authelia/access_control.yml into"
    echo "current_target/compose_live_state/authelia/config/configuration.yml."
    echo "Run on vps0 before docker compose up; --check does not write."
    exit 1
}

check_only=0
case "${1:-}" in
    "") ;;
    --check) check_only=1 ;;
    *) usage ;;
esac

require_target vps0

base_file="$INFRA_ROOT/targets/vps0/compose/files/authelia/configuration.base.yml"
rules_file="$INFRA_ROOT/config/vps0/authelia/access_control.yml"
env_file="$INFRA_ROOT/config/vps0/compose.env"
out_file="${COMPOSE_STATE_DIR:-$INFRA_ROOT/current_target/compose_live_state}/authelia/config/configuration.yml"

[ -f "$base_file" ] || { echo "Error: missing $base_file" >&2; exit 1; }
[ -f "$rules_file" ] || { echo "Error: missing $rules_file" >&2; exit 1; }
[ -f "$env_file" ] || { echo "Error: missing $env_file" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

render_vars() {
    local file="$1" var val esc
    for var in CLOUD_SERVICES_DOMAIN AUTHELIA_JWT_SECRET AUTHELIA_SESSION_SECRET AUTHELIA_REDIS_PASSWORD AUTHELIA_DB_ENCRYPTION_KEY; do
        val="${!var:-}"
        [ -n "$val" ] || { echo "Error: $var is not set in $env_file" >&2; return 1; }
        esc=${val//\\/\\\\}
        esc=${esc//&/\\&}
        esc=${esc//|/\\|}
        # Replace ${VAR} with its value without letting sed interpret the value.
        sed -i "s|\\\${$var}|$esc|g" "$file"
    done
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *"__AUTHELIA_ACCESS_RULES__"* ]]; then
        sed 's/^/    /' "$rules_file"
    else
        printf '%s\n' "$line"
    fi
done < "$base_file" > "$tmp"

render_vars "$tmp"

if [ "$check_only" = 1 ]; then
    if [ ! -f "$out_file" ]; then
        echo "Error: $out_file is missing; run $(basename "$0") on vps0" >&2
        exit 1
    fi
    if ! cmp -s "$tmp" "$out_file"; then
        echo "Error: $out_file is stale; run $(basename "$0") on vps0" >&2
        exit 1
    fi
    echo "render-vps0-authelia: OK"
    exit 0
fi

mkdir -p "$(dirname "$out_file")"
(umask 077; cp "$tmp" "$out_file")
chmod 600 "$out_file"
echo "render-vps0-authelia: wrote $out_file"
