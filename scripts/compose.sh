#!/bin/bash
# DESC: Run Docker Compose for a target with the repository's standard files,
# env files, machine facts, private overlay, and optional vps0 Authelia render.
#
# Usage: compose.sh <target> <compose-command...> [--dry-run]
#   compose.sh vps0 up -d
#   compose.sh pc logs -f syncthing
#   compose.sh vps0 config
#
# The target must be this machine's hostname for Compose operations.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target> <compose-command...> [--dry-run]" >&2
    echo "Example: $(basename "$0") vps0 up -d" >&2
    exit 1
}

[ $# -ge 2 ] || usage
target="$1"
shift

dry_run=0
args=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        dry_run=1
    else
        args+=("$arg")
    fi
done
[ ${#args[@]} -gt 0 ] || usage

require_target_host "$target"
target_dir="$INFRA_ROOT/targets/$target/compose"
[ -f "$target_dir/compose.yaml" ] || {
    echo "Error: $target_dir/compose.yaml not found" >&2
    exit 1
}

ensure_machine_env "$target"

compose_args=(-f "$target_dir/compose.yaml")
[ -f "$target_dir/compose.private.yaml" ] && compose_args+=(-f "$target_dir/compose.private.yaml")

# Config env first, machine facts second (later wins for collisions).
[ -f "$INFRA_ROOT/config/$target/compose.env" ] &&
    compose_args=(--env-file "$INFRA_ROOT/config/$target/compose.env" "${compose_args[@]}")
compose_args+=(--env-file "$target_dir/.env")

# Optional Compose profiles are declared in the config env. Passing them
# explicitly makes the behavior identical whether Compose was invoked by us or
# by hand.
profiles="$(config_env "$target" COMPOSE_PROFILES || true)"
if [ -n "$profiles" ]; then
    IFS=', ' read -r -a profile_list <<<"$profiles"
    for profile in "${profile_list[@]}"; do
        [ -n "$profile" ] && compose_args+=(--profile "$profile")
    done
fi

# The vps0 Authelia config is generated from the base + access rules. Keep the
# render automatic for `up` so it cannot go stale.
if [ "$target" = "vps0" ] && [ "${args[0]:-}" = "up" ] && [ "$dry_run" = 0 ] &&
    [ "${COMPOSE_SKIP_AUTHELIA_RENDER:-0}" != 1 ]; then
    bash "$INFRA_ROOT/scripts/render-vps0-authelia.sh"
fi

if [ "$dry_run" = 1 ]; then
    printf 'docker compose'
    printf ' %q' "${compose_args[@]}" "${args[@]}"
    printf '\n'
    exit 0
fi

exec docker compose "${compose_args[@]}" "${args[@]}"
