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
CLIENT_ID=$(kubectl exec -n apps deploy/immich-server -- node -e "
    const http = require('http');
    const req = http.get('http://localhost:2283/api/system-config', (res) => {
        let data = '';
        res.on('data', (c) => data += c);
        res.on('end', () => {
            try { const j = JSON.parse(data); process.stdout.write(j.oauth.clientId || ''); }
            catch(e) { process.stdout.write(''); }
        });
    });
    req.on('error', () => process.stdout.write(''));
    req.end();
" 2>/dev/null || echo "")

if [ -n "$CLIENT_ID" ]; then
    echo "OAuth already configured (clientId=$CLIENT_ID). Skipping."
    exit 0
fi

echo "OAuth not yet configured. Seeding configuration via API..."

kubectl exec -i -n apps deploy/immich-server -- env \
  ADMIN_EMAIL="$DOMAIN_OWNER_EMAIL" \
  SERVICES_DOMAIN="$SERVICES_DOMAIN" \
  CLIENT_SECRET="$AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE" \
  node <<'SEED'
const http = require('http');
const { execSync } = require('child_process');
const crypto = require('crypto');

function api(method, path, token, body) {
    return new Promise((resolve, reject) => {
        const opts = {
            hostname: 'localhost', port: 2283, path: path,
            method: method, headers: { 'Content-Type': 'application/json' }
        };
        if (token) opts.headers['Authorization'] = `Bearer ${token}`;
        const req = http.request(opts, (res) => {
            let data = '';
            res.on('data', (c) => data += c);
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch(e) { reject(new Error(`Invalid JSON: ${data}`)); }
            });
        });
        req.on('error', reject);
        if (body) req.write(JSON.stringify(body));
        req.end();
    });
}

async function seed() {
    const pwd = crypto.randomBytes(12).toString('hex');

    // Check if admin exists
    let hasAdmin = false;
    try {
        const users = execSync('immich-admin list-users', { encoding: 'utf8' });
        hasAdmin = JSON.parse(users).length > 0;
    } catch(e) {}

    if (!hasAdmin) {
        console.log('Creating admin user...');
        await api('POST', '/auth/admin-sign-up', null, {
            email: process.env.ADMIN_EMAIL,
            name: 'Admin',
            password: pwd
        });
        await new Promise(r => setTimeout(r, 2000));
    } else {
        console.log('Admin already exists, resetting password for API access...');
        execSync('immich-admin reset-admin-password', { input: pwd, encoding: 'utf8' });
        await new Promise(r => setTimeout(r, 2000));
    }

    const loginResp = await api('POST', '/auth/login', null, {
        email: process.env.ADMIN_EMAIL,
        password: pwd
    });
    const token = loginResp.accessToken;

    const config = await api('GET', '/system-config', token);

    config.oauth.enabled = true;
    config.oauth.issuerUrl = `https://auth.${process.env.SERVICES_DOMAIN}`;
    config.oauth.clientId = 'immich';
    config.oauth.clientSecret = process.env.CLIENT_SECRET;
    config.oauth.buttonText = 'Login with Authelia';
    config.oauth.autoRegister = true;
    config.oauth.autoLaunch = true;
    config.oauth.scope = 'openid profile email';
    config.ffmpeg.accel = 'vaapi';
    config.passwordLogin.enabled = false;
    config.library.watch.enabled = true;

    await api('PUT', '/system-config', token, config);

    console.log('Immich configuration seeded successfully.');
}

seed().catch(e => { console.error(e.message); process.exit(1); });
SEED

echo ""
echo "Immich configuration seeded."
echo "OAuth enabled, password login disabled, VAAPI acceleration active."
