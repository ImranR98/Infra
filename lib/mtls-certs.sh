#!/bin/bash
# mTLS cert generation.  Output to stdout/temp only; never touches VARS files.

_mtls_certs_temp_dir() {
    local d="/tmp/mtls-certs-$$"
    mkdir -p "$d"
    echo "$d"
}

generate_mtls_ca() {
    local outdir="$1"
    local subj="${2:-/CN=mtls-ca}"
    openssl req -x509 -newkey rsa:4096 \
        -keyout "$outdir/ca.key" \
        -out "$outdir/ca.crt" \
        -days 3650 -nodes \
        -subj "$subj" 2>/dev/null
}

generate_server_cert() {
    local outdir="$1"
    local ca_cert="$2"
    local ca_key="$3"
    local hostname="$4"
    shift 4
    local sans=("$@")

    local ssl_cnf="$outdir/openssl.cnf"
    cat > "$ssl_cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $hostname

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $hostname
EOF

    # Append additional SANs
    local i=2
    for san in "${sans[@]}"; do
        echo "DNS.$i = $san" >> "$ssl_cnf"
        i=$((i + 1))
    done

    openssl genrsa -out "$outdir/server.key" 2048 2>/dev/null
    openssl req -new -key "$outdir/server.key" -out "$outdir/server.csr" \
        -config "$ssl_cnf" 2>/dev/null
    openssl x509 -req -in "$outdir/server.csr" \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$outdir/server.crt" -days 1825 \
        -extfile "$ssl_cnf" -extensions req_ext 2>/dev/null
    rm -f "$outdir/server.csr" "$ssl_cnf"
}

generate_client_cert() {
    local outdir="$1"
    local ca_cert="$2"
    local ca_key="$3"
    local name="$4"

    openssl genrsa -out "$outdir/$name.key" 2048 2>/dev/null
    openssl req -new -key "$outdir/$name.key" \
        -out "$outdir/$name.csr" \
        -subj "/CN=$name" 2>/dev/null
    openssl x509 -req -in "$outdir/$name.csr" \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$outdir/$name.crt" -days 1825 2>/dev/null
    rm -f "$outdir/$name.csr"
}

print_copy_paste_block() {
    local target_label="$1"
    local var_name="$2"
    local file_path="$3"

    echo "  # $target_label"
    echo "  export $var_name=\"\$(cat <<'MTLS_CERT_EOF'"
    cat "$file_path"
    echo "MTLS_CERT_EOF"
    echo ")\""
    echo ""
}
