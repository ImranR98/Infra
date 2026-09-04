#!/bin/bash
# DESC: Scan for image, chart, and plugin updates across all stacks via Renovate
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

RENOVATE_BIN="renovate"
if ! command -v renovate >/dev/null 2>&1; then
    if command -v npx >/dev/null 2>&1; then
        RENOVATE_BIN="npx --yes renovate"
    else
        echo "Error: neither 'renovate' nor 'npx' found." >&2
        echo "Install with: npm install -g renovate" >&2
        exit 1
    fi
fi

_CONFIG_FILE="$INFRA_ROOT/renovate.json"
if [ ! -f "$_CONFIG_FILE" ]; then
    echo "Error: renovate.json not found at $_CONFIG_FILE" >&2
    exit 1
fi
export RENOVATE_CONFIG_FILE="$_CONFIG_FILE"

echo "Update Versions"
if [ "$DRY_RUN" = true ]; then echo "=== DRY RUN ==="; fi

_RENOVATE_LOG=$(mktemp /tmp/renovate-log.XXXXXX)
trap 'rm -f "$_RENOVATE_LOG"' EXIT

export LOG_LEVEL=debug LOG_FORMAT=json

echo "Scanning for updates via Renovate..."
_renovate_rc=0
$RENOVATE_BIN \
    --platform=local \
    --base-dir="$INFRA_ROOT" \
    --require-config=required \
    --onboarding=false \
    > "$_RENOVATE_LOG" 2>&1 || _renovate_rc=$?

if [ "$_renovate_rc" -ne 0 ] || ! grep -q 'packageFiles' "$_RENOVATE_LOG" 2>/dev/null; then
    echo "Warning: Renovate scan may have failed (exit=$_renovate_rc, check $_RENOVATE_LOG)" >&2
fi

_APPLY_PY="$INFRA_ROOT/commands/_internal/_apply_updates.py"
_TARGET_FLAG="--target=$TARGET"
if [ "$DRY_RUN" = true ]; then
    _APPLY_OUT=$(python3 "$_APPLY_PY" --dry-run "$_TARGET_FLAG" < "$_RENOVATE_LOG")
else
    _APPLY_OUT=$(python3 "$_APPLY_PY" "$_TARGET_FLAG" < "$_RENOVATE_LOG")
fi
echo "$_APPLY_OUT"

echo ""
echo "Checking Traefik plugins..."
for f in "$INFRA_ROOT/targets/$TARGET/compose/compose.yaml" "$INFRA_ROOT/targets/$TARGET/compose/compose.private.yaml" $(find "$INFRA_ROOT/targets/$TARGET/k3s" -name traefik.yaml 2>/dev/null); do
    [ -f "$f" ] || continue
    _plugin_tmp=$(mktemp)
    cp "$f" "$_plugin_tmp"

    while read -r mod_line; do
        _plugin_name="${mod_line##*plugins\.}"; _plugin_name="${_plugin_name%%.*}"
        _repo="${mod_line##*github.com/}"; _repo="${_repo%%[\" ]*}"
        _ver_line=$(grep -n "plugins\.$_plugin_name\.version=" "$f" | head -1)
        [ -n "$_ver_line" ] || continue

        _ver_num="${_ver_line##*=}"; _ver_num="${_ver_num%%[\" ]*}"

        _latest=$(curl -sf "https://api.github.com/repos/$_repo/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+') || continue
        [ "$_latest" = "$_ver_num" ] && continue

        echo "  $_plugin_name: $_ver_num -> $_latest (github.com/$_repo)"
        if [ "$DRY_RUN" = false ]; then
            _ver_num_esc=$(echo "$_ver_num" | sed 's/\./\\./g')
            sed -i "s|plugins\.$_plugin_name\.version=$_ver_num_esc|plugins.$_plugin_name.version=$_latest|" "$_plugin_tmp"
        fi
    done < <(grep -oP 'plugins\.[^.]+\.modulename=github\.com/[^\s"]+' "$f")

    if [ "$DRY_RUN" = false ] && ! cmp -s "$f" "$_plugin_tmp"; then
        cp "$_plugin_tmp" "$f"
        echo "  Updated $(basename "$f")"
    fi
    rm -f "$_plugin_tmp"
done

echo ""
echo "Done. Review changes with 'git diff' and run './infra.sh <target> validate'."
