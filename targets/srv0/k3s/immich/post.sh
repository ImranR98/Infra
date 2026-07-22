#!/bin/bash
# DESC: Seed Immich configuration via the internal API on first deploy.
#       Idempotent — skips if OAuth is already configured.
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"
source_env

echo "=== Checking Immich configuration ==="

# Wait for Immich server to be ready
if ! retry 60 5 "kubectl -n apps wait --for=condition=Ready pod -l app.kubernetes.io/name=server,app.kubernetes.io/instance=immich --timeout=10s >/dev/null 2>&1"; then
    echo "Error: Immich server did not become ready in time" >&2
    exit 1
fi

# Reset admin password and check idempotency in one shot.
# The password reset always succeeds (Inquirer raises ERR_USE_AFTER_CLOSE
# after setting the password — harmless).  We get a fresh token and
# check whether OAuth is already configured.
PWD=$(openssl rand -hex 12)

echo "Ensuring admin access..."
# Ensure password login is enabled so we can authenticate
kubectl exec -n apps deploy/immich-server -- \
    immich-admin enable-password-login 2>/dev/null || true

# Check if admin user exists
HAS_ADMIN=$(kubectl exec -n apps deploy/immich-server -- \
    immich-admin list-users 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [ "$HAS_ADMIN" = "0" ]; then
    echo "No admin user found. Creating via API..."
    kubectl exec -n apps deploy/immich-server -- \
        curl -sk -X POST "http://localhost:2283/api/auth/admin-sign-up" \
          -H "Content-Type: application/json" \
          -d "{\"email\":\"$DOMAIN_OWNER_EMAIL\",\"name\":\"Admin\",\"password\":\"$PWD\"}" 2>/dev/null
    sleep 2
else
    echo "Admin exists. Resetting password..."
    echo "$PWD" | kubectl exec -i -n apps deploy/immich-server -- \
        timeout 10 immich-admin reset-admin-password 2>/dev/null || true
fi

TOKEN=$(kubectl exec -n apps deploy/immich-server -- \
    curl -sk -X POST http://localhost:2283/api/auth/login \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$DOMAIN_OWNER_EMAIL\",\"password\":\"$PWD\"}" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
    echo "Error: could not obtain API token" >&2
    exit 1
fi

CLIENT_ID=$(kubectl exec -n apps deploy/immich-server -- \
    curl -sk "http://localhost:2283/api/system-config" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['oauth']['clientId'])" 2>/dev/null || echo "")

if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ]; then
    echo "OAuth already configured (clientId=$CLIENT_ID). Skipping."
    exit 0
fi

echo "OAuth not yet configured. Seeding configuration..."

# GET current config, patch, PUT back
CONFIG_JSON=$(kubectl exec -n apps deploy/immich-server -- \
    curl -sk "http://localhost:2283/api/system-config" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null)

UPDATED_JSON=$(echo "$CONFIG_JSON" | python3 -c "
import json, sys, os

c = json.load(sys.stdin)

c['oauth']['enabled'] = True
c['oauth']['issuerUrl'] = 'https://auth.$SERVICES_DOMAIN'
c['oauth']['clientId'] = 'immich'
c['oauth']['clientSecret'] = '$AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE'
c['oauth']['buttonText'] = 'Login with Authelia'
c['oauth']['autoRegister'] = True
c['oauth']['autoLaunch'] = True
c['oauth']['scope'] = 'openid profile email'
c['ffmpeg']['accel'] = 'vaapi'
c['passwordLogin']['enabled'] = False
c['library']['watch']['enabled'] = True

sys.stdout.write(json.dumps(c))
")

echo "$UPDATED_JSON" | kubectl exec -i -n apps deploy/immich-server -- \
    curl -sk -X PUT "http://localhost:2283/api/system-config" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d @- 2>/dev/null | python3 -c "
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
