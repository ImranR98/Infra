#!/bin/bash
# DESC: Seed Immich configuration via the internal API on first deploy.
#       Idempotent — skips if OAuth is already configured.
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"
source_env

echo "=== Checking Immich configuration ==="

# Wait for Immich server to be ready
if ! retry 60 5 "kubectl -n apps wait --for=condition=Ready pod -l app.kubernetes.io/name=server,app.kubernetes.io/instance=immich --timeout=10s >/dev/null 2>&1"; then
    echo "Error: Immich server did not become ready in time" >&2
    exit 1
fi

# Reset admin password and check idempotency in one shot.
# PWD is used in the printf heredoc below — kept short for the TTY pipe.

echo "Ensuring admin access..."
# Enable password login so we can authenticate
kubectl exec -n apps deploy/immich-server -- \
    immich-admin enable-password-login 2>/dev/null || true

# Try logging in as the expected admin. If admin doesn't exist, reset-admin-password
# or login will fail, and we fall back to creating one. This avoids the race
# condition where immich-admin list-users returns empty during server startup.
PWD=$(openssl rand -hex 12)

TOKEN=""
_try_login() {
    # Password rides stdin (-d @-), never argv (ps-visible on host + in pod).
    TOKEN=$(printf '{"email":"%s","password":"%s"}' "$DOMAIN_OWNER_EMAIL" "$1" | \
        kubectl exec -i -n apps deploy/immich-server -- \
        curl -sk -X POST http://localhost:2283/api/auth/login \
          -H "Content-Type: application/json" \
          -d @- 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null || echo "")
    [ -n "$TOKEN" ]
}

# Attempt 1: assume admin exists, reset its password and login
# immich-admin reset-admin-password uses an interactive Inquirer.js prompt that reads
# from /dev/tty. When stdin is a pipe (kubectl exec -i), Inquirer falls back to stdin
# but needs time between prompts. We send password, confirm, then with a delay the
# "Invalidate existing sessions?" answer so each lands on the right prompt.
echo "Admin exists. Resetting password..."
{ printf '%s\n%s\n' "$PWD" "$PWD"; sleep 3; printf 'Y\n'; } | kubectl exec -i -n apps deploy/immich-server -- \
    timeout 30 immich-admin reset-admin-password 2>/dev/null || true
sleep 2

if ! _try_login "$PWD"; then
    # Attempt 2: admin doesn't exist or password reset failed, create one
    echo "Login failed. Creating admin user..."
    printf '{"email":"%s","name":"Admin","password":"%s"}' "$DOMAIN_OWNER_EMAIL" "$PWD" | \
        kubectl exec -i -n apps deploy/immich-server -- \
        curl -sk -X POST "http://localhost:2283/api/auth/admin-sign-up" \
          -H "Content-Type: application/json" \
          -d @- 2>/dev/null
    sleep 2
    if ! _try_login "$PWD"; then
        echo "Error: could not create or authenticate as admin" >&2
        exit 1
    fi
fi

# Authenticated exec calls below pass the bearer token over stdin into a
# remote shell var (IFS= read -r tok), keeping it out of kubectl/curl argv.
CLIENT_ID=$(printf '%s\n' "$TOKEN" | kubectl exec -i -n apps deploy/immich-server -- \
    sh -c 'IFS= read -r tok; curl -sk "http://localhost:2283/api/system-config" \
        -H "Authorization: Bearer $tok" 2>/dev/null' | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['oauth']['clientId'])" 2>/dev/null || echo "")

if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ]; then
    echo "OAuth already configured (clientId=$CLIENT_ID). Skipping."
    exit 0
fi

echo "OAuth not yet configured. Seeding configuration..."

# GET current config, patch, PUT back
CONFIG_JSON=$(printf '%s\n' "$TOKEN" | kubectl exec -i -n apps deploy/immich-server -- \
    sh -c 'IFS= read -r tok; curl -sk "http://localhost:2283/api/system-config" \
        -H "Authorization: Bearer $tok" 2>/dev/null')

# Client secret comes via env (not argv) into the python below.
UPDATED_JSON=$(AUTHELIA_IMMICH_CLIENT_SECRET="$AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE" \
    python3 -c "
import json, sys, os

c = json.load(sys.stdin)

c['oauth']['enabled'] = True
c['oauth']['issuerUrl'] = 'https://auth.$SERVICES_DOMAIN'
c['oauth']['clientId'] = 'immich'
c['oauth']['clientSecret'] = os.environ['AUTHELIA_IMMICH_CLIENT_SECRET']
c['oauth']['buttonText'] = 'Login with Authelia'
c['oauth']['autoRegister'] = True
c['oauth']['autoLaunch'] = True
c['oauth']['scope'] = 'openid profile email'
c['ffmpeg']['accel'] = 'vaapi'
c['passwordLogin']['enabled'] = False
c['library']['watch']['enabled'] = True

sys.stdout.write(json.dumps(c))
" <<< "$CONFIG_JSON")

{ printf '%s\n' "$TOKEN"; printf '%s\n' "$UPDATED_JSON"; } | kubectl exec -i -n apps deploy/immich-server -- \
    sh -c 'IFS= read -r tok; curl -sk -X PUT "http://localhost:2283/api/system-config" \
        -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null' | python3 -c "
import json, sys
c = json.load(sys.stdin)
o = c['oauth']
assert o['enabled'] == True
assert o['clientId'] == 'immich'
assert c['passwordLogin']['enabled'] == False
print('ok')
" 2>/dev/null

echo ""
echo "Immich configuration seeded."
echo "OAuth enabled, password login disabled, VAAPI acceleration active."
