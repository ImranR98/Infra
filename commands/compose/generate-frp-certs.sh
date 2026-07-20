#!/bin/bash
# DESC: Generate FRP mTLS certificates for a client↔server pair.
#       Prints copy-paste blocks for VARS files. Never modifies VARS files.
#       Run from the client target (srv0 or pc0).
# Usage: ./atlas.sh <client-target> compose generate-frp-certs <server-target>
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
source "$ATLAS_ROOT/lib/frp-certs.sh"

SERVER_TARGET="$1"
if [ -z "$SERVER_TARGET" ] || [ ! -f "$ATLAS_ROOT/targets/$SERVER_TARGET/VARS.template.sh" ]; then
    echo "Usage: $0 <target> compose generate-frp-certs <server-target>" >&2
    echo "  <server-target> is the VPS running frps (e.g., vps0 or vps1)" >&2
    exit 1
fi

CLIENT_TARGET="$TARGET"
CLIENT_VARS="$ATLAS_ROOT/targets/$CLIENT_TARGET/VARS.template.sh"
SERVER_VARS="$ATLAS_ROOT/targets/$SERVER_TARGET/VARS.template.sh"

# Determine server hostname from VARS template or use PROXY_HOST
PROXY_HOST_VAL=""
if grep -q "^export PROXY_HOST=" "$CLIENT_VARS" 2>/dev/null; then
    PROXY_HOST_VAL=$(grep "^export PROXY_HOST=" "$CLIENT_VARS" | sed 's/^export PROXY_HOST=//; s/"//g' | head -1)
fi
SERVER_HOSTNAME="${PROXY_HOST_VAL:-$SERVER_TARGET}"

echo "=== FRP mTLS Certificate Generator ==="
echo "Client: $CLIENT_TARGET"
echo "Server: $SERVER_TARGET ($SERVER_HOSTNAME)"
echo ""

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found." >&2
    exit 1
fi

OUTDIR="$(_frp_certs_temp_dir)"
trap 'rm -rf "$OUTDIR"' EXIT

echo "Generating CA..."
generate_frp_ca "$OUTDIR"

echo "Generating server certificate for $SERVER_HOSTNAME..."
generate_server_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$SERVER_HOSTNAME"

echo "Generating client certificate for $CLIENT_TARGET..."
generate_client_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$CLIENT_TARGET-client"

HAS_PREBOOT=false
if grep -q "FRP_PREBOOT_CLIENT_CERT" "$CLIENT_VARS" 2>/dev/null; then
    HAS_PREBOOT=true
    echo "Generating preboot client certificate for $CLIENT_TARGET..."
    generate_client_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$CLIENT_TARGET-preboot"
fi

echo ""
echo "=== Certificates generated ==="
echo ""

# --- Print VARS.sh (common, for client) ---
echo "Paste into VARS.${CLIENT_TARGET}.sh:"
echo ""
echo "  # --- FRP CA (shared for this pair) ---"
print_copy_paste_block "$CLIENT_TARGET" "FRP_CA_CERT" "$OUTDIR/ca.crt"
print_copy_paste_block "$CLIENT_TARGET" "FRP_CA_KEY" "$OUTDIR/ca.key"

echo "  # --- FRP client certificate ---"
print_copy_paste_block "$CLIENT_TARGET" "FRP_CLIENT_CERT" "$OUTDIR/$CLIENT_TARGET-client.crt"
print_copy_paste_block "$CLIENT_TARGET" "FRP_CLIENT_KEY" "$OUTDIR/$CLIENT_TARGET-client.key"

if [ "$HAS_PREBOOT" = true ]; then
    echo "  # --- FRP preboot client certificate ---"
    print_copy_paste_block "$CLIENT_TARGET" "FRP_PREBOOT_CLIENT_CERT" "$OUTDIR/$CLIENT_TARGET-preboot.crt"
    print_copy_paste_block "$CLIENT_TARGET" "FRP_PREBOOT_CLIENT_KEY" "$OUTDIR/$CLIENT_TARGET-preboot.key"
fi

# --- Print VARS for server ---
echo "Paste into VARS.${SERVER_TARGET}.sh:"
echo ""
echo "  # --- FRP CA (shared for this pair) ---"
print_copy_paste_block "$SERVER_TARGET" "FRP_CA_CERT" "$OUTDIR/ca.crt"

echo "  # --- FRP server certificate ---"
print_copy_paste_block "$SERVER_TARGET" "FRP_SERVER_CERT" "$OUTDIR/server.crt"
print_copy_paste_block "$SERVER_TARGET" "FRP_SERVER_KEY" "$OUTDIR/server.key"

echo ""
echo "Files also available at: $OUTDIR"
echo "(will be cleaned up when this script exits unless you Ctrl-C now)"
