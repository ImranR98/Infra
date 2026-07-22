#!/bin/bash
# DESC: Seed Immich configuration via the internal API on first deploy.
#       Idempotent — skips if OAuth is already configured.
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"
source_env

echo "=== Checking Immich configuration ==="

# Wait for Immich server to be ready
if ! retry 60 5 "kubectl -n apps wait --for=condition=Ready pod -l app.kubernetes.io/name=immich-server --timeout=10s >/dev/null 2>&1"; then
    echo "Error: Immich server did not become ready in time" >&2
    exit 1
fi

# Idempotency check: skip if OAuth already configured
CLIENT_ID=$(kubectl exec -n apps deploy/immich-server -- \
    python3 -c "import json,subprocess; r=subprocess.run(['curl','-sk','http://localhost:2283/api/system-config'],capture_output=True,text=True); print(json.loads(r.stdout)['oauth']['clientId'])" 2>/dev/null || echo "")

if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ]; then
    echo "OAuth already configured (clientId=$CLIENT_ID). Skipping."
    exit 0
fi

echo "OAuth not yet configured. Seeding configuration via API..."

kubectl exec -i -n apps deploy/immich-server -- env \
  ADMIN_EMAIL="$DOMAIN_OWNER_EMAIL" \
  SERVICES_DOMAIN="$SERVICES_DOMAIN" \
  CLIENT_SECRET="$AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE" \
  python3 <<'SEED'
import json, subprocess, os, secrets, sys, time

def api(method, path, token=None, body=None):
    args = ["curl", "-sk", f"http://localhost:2283{path}"]
    if token:
        args += ["-H", f"Authorization: Bearer {token}"]
    if body is not None:
        args += ["-H", "Content-Type: application/json"]
        args += ["-d", json.dumps(body)]
    args += ["-X", method.upper()]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"API call failed: {method} {path}", file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        print(f"API returned non-JSON: {method} {path}", file=sys.stderr)
        print(r.stdout, file=sys.stderr)
        sys.exit(1)

# Check if an admin user exists
admin_list = subprocess.run(
    ["immich-admin", "list-users"], capture_output=True, text=True
)
has_admin = False
try:
    users = json.loads(admin_list.stdout)
    has_admin = len(users) > 0
except (json.JSONDecodeError, TypeError):
    pass

pwd = secrets.token_hex(16)

if not has_admin:
    print("Creating admin user...")
    api("POST", "/auth/admin-sign-up", body={
        "email": os.environ["ADMIN_EMAIL"],
        "name": "Admin",
        "password": pwd
    })
    # Wait briefly for the server to process the sign-up
    time.sleep(2)
else:
    print("Admin already exists, resetting password for API access...")
    subprocess.run(
        ["immich-admin", "reset-admin-password"],
        input=pwd, text=True, capture_output=True
    )
    time.sleep(2)

token = api("POST", "/auth/login", body={
    "email": os.environ["ADMIN_EMAIL"],
    "password": pwd
})["accessToken"]

config = api("GET", "/system-config", token=token)

config["oauth"]["enabled"] = True
config["oauth"]["issuerUrl"] = f"https://auth.{os.environ['SERVICES_DOMAIN']}"
config["oauth"]["clientId"] = "immich"
config["oauth"]["clientSecret"] = os.environ["CLIENT_SECRET"]
config["oauth"]["buttonText"] = "Login with Authelia"
config["oauth"]["autoRegister"] = True
config["oauth"]["autoLaunch"] = True
config["oauth"]["scope"] = "openid profile email"
config["ffmpeg"]["accel"] = "vaapi"
config["passwordLogin"]["enabled"] = False
config["library"]["watch"]["enabled"] = True

api("PUT", "/system-config", token=token, body=config)

print("Immich configuration seeded successfully.")
SEED

echo ""
echo "Immich configuration seeded."
echo "OAuth enabled, password login disabled, VAAPI acceleration active."
echo "Admin password was set to a random value — use Authelia SSO to log in."
