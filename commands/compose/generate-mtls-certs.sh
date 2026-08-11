#!/bin/bash
# DESC: Generate mTLS certificates for a client↔server pair.
#       Prints copy-paste blocks for VARS files. Never modifies VARS files.
#       Run from any client/non-proxy target.
# Usage: ./infra.sh <client-target> compose generate-mtls-certs <server-target>
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
source "$INFRA_ROOT/lib/mtls-certs.sh"

SERVER_TARGET="$1"
if [ -z "$SERVER_TARGET" ] || [ ! -f "$INFRA_ROOT/targets/$SERVER_TARGET/VARS.template.sh" ]; then
    echo "Usage: $0 <target> compose generate-mtls-certs <server-target>" >&2
    echo "  <server-target> is the target running the server side of the pair (e.g., vps0)" >&2
    exit 1
fi

CLIENT_TARGET="$TARGET"
CLIENT_VARS_TPL="$INFRA_ROOT/targets/$CLIENT_TARGET/VARS.template.sh"
SERVER_VARS_TPL="$INFRA_ROOT/targets/$SERVER_TARGET/VARS.template.sh"

echo "=== mTLS Certificate Generator ==="
echo "Client: $CLIENT_TARGET"
echo "Server: $SERVER_TARGET"
echo ""

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found." >&2
    exit 1
fi

OUTDIR="$(_mtls_certs_temp_dir)"
trap 'rm -rf "$OUTDIR"' EXIT

echo "Generating CA..."
generate_mtls_ca "$OUTDIR"

echo "Generating server certificate..."
generate_server_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$SERVER_TARGET"

echo "Generating client certificate for $CLIENT_TARGET..."
generate_client_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$CLIENT_TARGET-client"

HAS_PREBOOT=false
if grep -q "MTLS_PREBOOT_CLIENT_CERT" "$CLIENT_VARS_TPL" 2>/dev/null; then
    HAS_PREBOOT=true
    echo "Generating preboot client certificate for $CLIENT_TARGET..."
    generate_client_cert "$OUTDIR" "$OUTDIR/ca.crt" "$OUTDIR/ca.key" "$CLIENT_TARGET-preboot"
fi

echo ""
echo "=== Certificates generated ==="
echo ""

# ====== Print VARS.sh (common, for client) ======
echo "Paste into VARS.${CLIENT_TARGET}.sh:"
echo ""
echo "# --- mTLS CA (shared for this pair) ---"
print_copy_paste_block "$CLIENT_TARGET" "MTLS_CA_CERT" "$OUTDIR/ca.crt"
print_copy_paste_block "$CLIENT_TARGET" "MTLS_CA_KEY" "$OUTDIR/ca.key"

echo "# --- mTLS client certificate ---"
print_copy_paste_block "$CLIENT_TARGET" "MTLS_CLIENT_CERT" "$OUTDIR/$CLIENT_TARGET-client.crt"
print_copy_paste_block "$CLIENT_TARGET" "MTLS_CLIENT_KEY" "$OUTDIR/$CLIENT_TARGET-client.key"

if [ "$HAS_PREBOOT" = true ]; then
    echo "# --- mTLS preboot client certificate ---"
    print_copy_paste_block "$CLIENT_TARGET" "MTLS_PREBOOT_CLIENT_CERT" "$OUTDIR/$CLIENT_TARGET-preboot.crt"
    print_copy_paste_block "$CLIENT_TARGET" "MTLS_PREBOOT_CLIENT_KEY" "$OUTDIR/$CLIENT_TARGET-preboot.key"
fi

# ====== Print VARS for server ======
echo "Paste into VARS.${SERVER_TARGET}.sh:"
echo ""
echo "# --- mTLS CA (shared for this pair) ---"
print_copy_paste_block "$SERVER_TARGET" "MTLS_CA_CERT" "$OUTDIR/ca.crt"

echo "# --- mTLS server certificate ---"
print_copy_paste_block "$SERVER_TARGET" "MTLS_SERVER_CERT" "$OUTDIR/server.crt"
print_copy_paste_block "$SERVER_TARGET" "MTLS_SERVER_KEY" "$OUTDIR/server.key"

echo ""
echo "Files also available at: $OUTDIR"
echo "(will be cleaned up when this script exits)"
