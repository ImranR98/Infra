#!/bin/bash
# Shared configuration readers. Sourced by common.sh so scripts do not each
# reimplement dotenv/YAML parsing.

# config_yaml <target> <yq-path> — read a string from config/<target>/values.yaml.
config_yaml() {
    local target="$1" path="$2"
    local file="$INFRA_ROOT/config/$target/values.yaml"
    [ -f "$file" ] || return 1
    yq -r "${path} // \"\"" "$file" 2>/dev/null
}

# config_env <target> <KEY> — read one value from config/<target>/compose.env
# with shell-compatible quoting. The file is sourced in a subshell, so values
# containing spaces or $ are handled the same way Compose/Docker handle them.
config_env() {
    local target="$1" key="$2"
    local file="$INFRA_ROOT/config/$target/compose.env"
    [ -f "$file" ] || return 1
    (
        set -a
        # shellcheck disable=SC1090
        . "$file" >/dev/null 2>&1
        printf '%s' "${!key-}"
    )
}

# config_has <target> <file> — true when a non-empty regular config file exists.
config_has() {
    [ -s "$INFRA_ROOT/config/$1/$2" ]
}
