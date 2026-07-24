#!/bin/bash
# DESC: Browser-based integration tests for all exposed services
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"
source_env

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
VENV_DIR="$SCRIPT_DIR/.venv"
DOMAINS_FILE=$(mktemp)

cleanup() { rm -f "$DOMAINS_FILE"; }
trap cleanup EXIT

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

if ! python3 -c "import playwright" 2>/dev/null; then
    echo "Installing Playwright (one-time)..."
    pip install playwright
    playwright install chromium
fi

list_domains srv0 > "$DOMAINS_FILE"

export COOKIES_FILE="$SCRIPT_DIR/.cookies.json"

if command -v ujust >/dev/null 2>&1; then
    ujust with-standard-malloc python3 "$SCRIPT_DIR/_services_test.py" "$SERVICES_DOMAIN" "$DOMAINS_FILE"
else
    python3 "$SCRIPT_DIR/_services_test.py" "$SERVICES_DOMAIN" "$DOMAINS_FILE"
fi
