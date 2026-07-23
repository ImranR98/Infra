#!/bin/bash
# authelia-specific compose prep: format users_database.yml with 2-space indentation
# Authelia expects users_database.yml keys indented 2 spaces deeper than the
# $AUTHELIA_USERS_DATABASE block scalar in VARS.
set -euo pipefail

COMPOSE_STATE_DIR="${ATLAS_ROOT:?}/current_target/compose_live_state"
mkdir -p "$COMPOSE_STATE_DIR/authelia/config"

printf '%s\n' "${AUTHELIA_USERS_DATABASE:?}" | \
    awk 'NR==1{print} NR>1&&/./{print "  " $0} NR>1&&!/./{print}' \
    > "$COMPOSE_STATE_DIR/authelia/config/users_database.yml"
