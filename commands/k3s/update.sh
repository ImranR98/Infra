#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

DRY_RUN=false
FILTER=""
VERBOSE=false

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=true ;;
		--verbose|-v) VERBOSE=true ;;
		--filter=*) FILTER="${1#*=}" ;;
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

_CONFIG_FILE="$ATLAS_ROOT/renovate.json"
if [ ! -f "$_CONFIG_FILE" ]; then
	echo "Error: renovate.json not found at $_CONFIG_FILE" >&2
	exit 1
fi
export RENOVATE_CONFIG_FILE="$_CONFIG_FILE"

echo "Update Versions"
[ "$DRY_RUN" = true ] && echo "=== DRY RUN ==="

_RENOVATE_LOG=$(mktemp /tmp/renovate-log.XXXXXX)
trap 'rm -f "$_RENOVATE_LOG"' EXIT

export LOG_LEVEL=debug LOG_FORMAT=json

echo "Scanning for updates via Renovate..."
$RENOVATE_BIN \
	--platform=local \
	--token="" \
	--base-dir="$ATLAS_ROOT" \
	--require-config=required \
	--onboarding=false \
	> "$_RENOVATE_LOG" 2>&1 || true

_APPLY_PY="$ATLAS_ROOT/commands/k3s/_apply_updates.py"
if [ "$DRY_RUN" = true ]; then
	python3 "$_APPLY_PY" --dry-run < "$_RENOVATE_LOG"
else
	python3 "$_APPLY_PY" < "$_RENOVATE_LOG"
fi

echo ""
echo "Done. Review changes with 'git diff' and run './atlas.sh <target> validate'."