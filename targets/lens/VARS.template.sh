# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"

# --- Logtfy ---
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16

# --- FRP ---
export FRPC_TOKEN="change_me" # openssl rand -hex 128
export FRPC_PREBOOT_TOKEN="change_me" # openssl rand -hex 128
