# Secrets Hardening

This document is the result of a full security audit of all Kubernetes and Docker Compose manifests in the Atlas repository. It covers: what was found, what is already correctly handled, what isn't, and a concrete fix plan for the remaining issues.

---

## Audit methodology

Every YAML/JSON manifest under `targets/` was scanned for:

- Literal credential values (passwords, tokens, API keys, private keys)
- Credentials stored in ConfigMaps, Deployments, CRDs, or Helm `valuesContent` blocks (i.e., non-`kind: Secret` resources)
- Credentials stored correctly in `kind: Secret` resources with `stringData:` or `secretKeyRef` references

The live cluster at `imranr@192.168.0.XX` was inspected to verify runtime state of the Authelia ConfigMap and Secret resources.

---

## Findings summary

| Category | Count | Status |
|----------|-------|--------|
| Literal hardcoded values in non-Secret resources | 2 | Needs fixing |
| Secrets stored in ConfigMap/CRD at runtime | 2 | Needs fixing |
| Properly stored in K8s Secrets via variables | 35+ | Already correct |
| Pre-existing template (`change_me`) files | 4 | Already correct |

---

## Finding 1: Literal `postgres` password in Docker Compose

**File:** `targets/vps0/compose/compose.yaml:222`

```yaml
environment:
    - POSTGRES_PASSWORD=postgres
```

The `plausible_db` PostgreSQL container uses the literal default password `"postgres"` — not a variable reference. This is committed to the repo in a non-Secret deployment descriptor.

**Severity:** High. Anyone with read access to the repo can see the DB password for this container.

**Fix:** Replace with `$PLAUSIBLE_DB_PASSWORD` and add the variable to `VARS.template.sh`.

---

## Finding 2: Literal `admin1` password in OpenCanary honeycred

**File:** `targets/srv0/k3s/opencanary/prereqs.yaml:139`

```json
{"username": "admin", "password": "admin1"}
```

This is inside a `kind: Secret` resource (`opencanary-config`), but the value `"admin1"` is a literal string committed to git — not a `$VARIABLE` reference. The actual credential lives in the repo.

**Severity:** Medium. It's a honeycred for an intrusion-detection honeypot, so a weak password is somewhat by design, but it should still use variable substitution.

**Fix:** Replace with `$OPENCANARY_HONEYCRED_PASSWORD` and add the variable to `VARS.template.sh`.

---

## Finding 3: Authelia secrets in ConfigMap at runtime

**Files:**
- `targets/srv0/k3s/authelia/helmchart.yaml`
- `targets/srv0/k3s/authelia/prereqs.yaml`

**Initial assessment:** The Authelia Helm chart (`0.11.6`) uses a `configMap:` block in `valuesContent` containing DB password, Redis password, encryption keys, and OIDC secrets. This was flagged as all secrets leaking into a ConfigMap at runtime.

**Verified runtime state** (live cluster, July 2026): The chart **correctly separates most secrets** into a proper K8s Secret. The `authelia` Secret in namespace `base` contains:

| Secret key | Value |
|---|---|
| `session.redis.password.txt` | Redis password |
| `storage.postgres.password.txt` | PostgreSQL password |
| `storage.encryption.key` | DB encryption key |
| `session.encryption.key` | Session encryption key |
| `identity_providers.oidc.hmac.key` | OIDC HMAC secret |
| `identity_validation.reset_password.jwt.hmac.key` | JWT signing key |

None of these appear in the ConfigMap's `configuration.yaml`. The chart writes file-path references (e.g., `/secrets/session.redis.password.txt`) into the ConfigMap and stores the real values in the Secret. Authelia reads those files at startup.

**However, two values ARE leaking into the ConfigMap:**

1. **OIDC client secrets** — hashed `$plaintext$...` values for immich and open-webui clients stored directly in the ConfigMap
2. **JWKS RSA private key** — a full `-----BEGIN PRIVATE KEY-----` block embedded in the ConfigMap

These leak because the `helmchart.yaml` uses a plain `value:` format instead of `path:` for these two fields. The chart supports a `path:` alternative that writes a file-path reference into the ConfigMap instead of the raw value.

**Severity:** Medium. The critical credentials (DB, Redis, encryption) are fine. The private key and client secrets are the remaining leaks.

---

## Finding 4: CrowdSec bouncer key in Traefik Middleware CRD at runtime

**File:** `targets/srv0/k3s/traefik/middlewares.yaml:47`

```yaml
# NOTE: The bouncer key is inline because Traefik plugin Middleware CRDs
# do not support valueFrom.secretKeyRef — only plain string values.
crowdsecLapiKey: $CROWDSEC_BOUNCER_KEY
```

The repo uses `$VARIABLE` (safe), but at runtime the resolved value ends up in a Traefik Middleware CRD — a non-Secret Kubernetes resource. The file documents this as a limitation of the Traefik plugin CRD format.

**Severity:** Low (repo) / Medium (runtime). The value in the repo is a safe variable reference. The runtime exposure is a known Traefik limitation. Monitor the Traefik plugin API for future `secretKeyRef` support.

---

## What is already correct

The following mechanisms are in good shape and require no changes:

### Kubernetes Secrets with `stringData:` + variable substitution

19 `kind: Secret` resources across 14 files use `stringData:` with `$VARIABLE_NAME` references. No actual secret values are committed to git. Examples:

- `crowdsec/prereqs.yaml` — bouncer keys, LAPI configs with ntfy tokens
- `ntfy/prereqs.yaml` — auth users/tokens, server config
- `immich/prereqs.yaml` — DB credentials
- `nextcloud/prereqs.yaml` — admin credentials, DB password
- `freshrss/prereqs.yaml` — user credentials
- `mosquitto/prereqs.yaml` — MQTT credentials
- `fmd/prereqs.yaml` — registration token
- `dscpln/prereqs.yaml` / `mdscl/prereqs.yaml` — ntfy tokens
- `ollama/prereqs.yaml` — OIDC client secret
- `logtfy/logtfy.yaml` — config with ntfy token

### `valueFrom.secretKeyRef` in Deployments/HelmCharts

15+ environment variables use `secretKeyRef` to inject secrets from K8s Secrets into pods:

- `authelia/prereqs.yaml` — `POSTGRES_PASSWORD`, `REDIS_PASSWORD`
- `immich/helmchart.yaml` — `DB_PASSWORD`
- `nextcloud/nextcloud.yaml` — `NEXTCLOUD_ADMIN_PASSWORD`, `POSTGRES_PASSWORD`
- `ntfy/ntfy.yaml` — `NTFY_AUTH_USERS`, `NTFY_AUTH_TOKENS`, `NTFY_AUTH_ACCESS`
- `fmd/fmd.yaml` — `FMD_REGISTRATIONTOKEN`
- `dscpln/dscpln.yaml` / `mdscl/mdscl.yaml` — `NTFY_TOKEN`
- `crowdsec/helmchart.yaml` — `BOUNCER_KEY_traefik`
- `ollama/openwebui-helmchart.yaml` — `OAUTH_CLIENT_SECRET`

### Docker Compose variable substitution

All Docker Compose credentials use `${VARIABLE}` or `$VARIABLE` substitution. The rendered live state is gitignored.

### Template files

`VARS.template.sh` files in every target use `"change_me"` placeholders with comments suggesting secure generation commands. These are templates, not deployed directly.

---

## Authelia fix plan

### Current state

The `authelia` Helm chart (`0.11.6`, repo: `https://charts.authelia.com`) generates two resources:

1. A **ConfigMap** (`authelia`) containing `configuration.yaml` — the full Authelia configuration
2. A **Secret** (`authelia`) containing all values that use the chart's secret schema

The chart's secret schema works like this: when a field is configured as an object with `value:` (rather than as a plain string), the chart:
- Writes the actual value into the generated Secret at a sub-path like `/secrets/<path>`
- Writes a file-path reference (e.g., `/secrets/session.redis.password.txt`) into the ConfigMap instead of the raw value
- Authelia reads the file from disk at startup

This already works correctly for: DB password, Redis password, DB encryption key, session encryption key, and OIDC HMAC secret.

### What needs to change

Two fields use plain `value:` format, which causes the chart to embed them directly in the ConfigMap:

1. `jwks[0].key.value` — RSA private key (lines 97-99 of `helmchart.yaml`)
2. `clients[].client_secret` — OIDC client secrets (lines 103, 119)

The chart schema supports a `path:` alternative for both, which writes a file-path reference into the ConfigMap. The actual value must be provided as a mounted file — either via the chart's `additionalSecrets` mechanism or via a standard K8s Secret with `extraVolumes`.

We use `extraVolumes` because the existing pod spec already uses this pattern (for the `authelia-users` Secret).

### Files to modify

Both files are under `targets/srv0/k3s/authelia/`:

1. **`prereqs.yaml`** — add 1 new `kind: Secret` resource
2. **`helmchart.yaml`** — add 1 volume, 1 volumeMount, change 3 value entries

No changes to other services. The `openwebui-oidc` Secret in `ollama/prereqs.yaml` and `immich-db-credentials` in `immich/prereqs.yaml` already use `secretKeyRef` correctly.

---

### Step 1: New Secret in `prereqs.yaml`

Append a new Secret resource at the end of `prereqs.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: authelia-oidc-secrets
  namespace: base
type: Opaque
stringData:
  jwks.private-key.pem: |
    $AUTHELIA_JWKS_KEY
  oidc.immich.client-secret: "$plaintext$$AUTHELIA_IMMICH_CLIENT_SECRET"
  oidc.openwebui.client-secret: "$plaintext$$AUTHELIA_OPENWEBUI_CLIENT_SECRET"
```

**What this does:**

Three keys map to the same three env variables already in use. The values are identical to what currently gets embedded in the ConfigMap — but now they're stored in a proper K8s Secret resource. The `$plaintext$` prefix is an Authelia convention for hashed client secrets; it passes through unchanged.

The Secret lives in `namespace: base` (same as all other Authelia resources).

---

### Step 2: Volume mount in `helmchart.yaml`

The pod spec (lines 14-33) already mounts one external Secret (`authelia-users`) via `extraVolumeMounts` and `extraVolumes`. Add a second pair for the new Secret.

**Current state** (lines 25-35):

```yaml
pod:
  kind: Deployment
  resources:
    limits:
      memory: 2Gi
    requests:
      memory: 128Mi
  probes:
    startup:
      failureThreshold: 30
  extraVolumeMounts:
    - name: users-database
      mountPath: "/config/users"
      readOnly: true
  extraVolumes:
    - name: users-database
      secret:
        secretName: authelia-users
        items:
          - key: users-database.yaml
            path: users-database.yaml
```

**After changes:**

```yaml
pod:
  kind: Deployment
  resources:
    limits:
      memory: 2Gi
    requests:
      memory: 128Mi
  probes:
    startup:
      failureThreshold: 30
  extraVolumeMounts:
    - name: users-database
      mountPath: "/config/users"
      readOnly: true
    - name: oidc-secrets
      mountPath: "/secrets/oidc"
      readOnly: true
  extraVolumes:
    - name: users-database
      secret:
        secretName: authelia-users
        items:
          - key: users-database.yaml
            path: users-database.yaml
    - name: oidc-secrets
      secret:
        secretName: authelia-oidc-secrets
```

**Why `/secrets/oidc/`:**

- The chart already mounts its auto-generated Secret at `/secrets/` (the default `secret.mountPath`)
- Adding a separate mount at `/secrets/oidc/` doesn't conflict — it's a different volume, different keys, creating a subdirectory under the existing tree
- The resulting files are at:
  - `/secrets/oidc/jwks.private-key.pem`
  - `/secrets/oidc/oidc.immich.client-secret`
  - `/secrets/oidc/oidc.openwebui.client-secret`

No `items:` sub-path mapping is needed here because the Secret's keys match the desired filenames exactly.

---

### Step 3: Change `value:` to `path:` in `valuesContent`

Three edits inside the `configMap.identity_providers.oidc:` block (lines 96-136):

**Edit A: JWKS private key** (lines 97-99)

```yaml
# Before:
          jwks:
            - key:
                value: |
                  $AUTHELIA_JWKS_KEY
```

```yaml
# After:
          jwks:
            - key:
                path: '/secrets/oidc/jwks.private-key.pem'
```

**Edit B: Immich client secret** (line 103)

```yaml
# Before:
          clients:
          - client_id: 'immich'
            client_name: 'immich'
            client_secret: '$plaintext$$AUTHELIA_IMMICH_CLIENT_SECRET'
```

```yaml
# After:
          clients:
          - client_id: 'immich'
            client_name: 'immich'
            client_secret:
              path: '/secrets/oidc/oidc.immich.client-secret'
```

**Edit C: Open-webui client secret** (line 119)

```yaml
# Before:
          - client_id: 'open-webui'
            client_name: 'Open WebUI'
            client_secret: '$plaintext$$AUTHELIA_OPENWEBUI_CLIENT_SECRET'
```

```yaml
# After:
          - client_id: 'open-webui'
            client_name: 'Open WebUI'
            client_secret:
              path: '/secrets/oidc/oidc.openwebui.client-secret'
```

---

### Resulting ConfigMap after the fix

After the Helm release is upgraded, `kubectl get configmap -n base authelia -o yaml` will show:

```yaml
# In configuration.yaml:
jwks:
  - key:
      path: '/secrets/oidc/jwks.private-key.pem'
# ...
clients:
  - client_id: 'immich'
    client_secret:
      path: '/secrets/oidc/oidc.immich.client-secret'
  - client_id: 'open-webui'
    client_secret:
      path: '/secrets/oidc/oidc.openwebui.client-secret'
```

No raw private key, no hashed client secrets. The ConfigMap is clean.

### Verification steps after deployment

```bash
# 1. Confirm the new Secret exists and has data
kubectl get secret -n base authelia-oidc-secrets -o yaml

# 2. Confirm the ConfigMap no longer contains raw secrets
kubectl get configmap -n base authelia -o jsonpath='{.data.configuration\.yaml}' | grep -c 'PRIVATE KEY'
# Expected: 0

kubectl get configmap -n base authelia -o jsonpath='{.data.configuration\.yaml}' | grep -c '\$plaintext'
# Expected: 0

# 3. Confirm the existing chart Secret is untouched
kubectl get secret -n base authelia -o jsonpath='{.data}' | jq 'keys'
# Should still contain: session.redis.password.txt, storage.postgres.password.txt,
#   storage.encryption.key, session.encryption.key, identity_providers.oidc.hmac.key,
#   identity_validation.reset_password.jwt.hmac.key

# 4. Check that Authelia pod starts successfully
kubectl get pods -n base -l app.kubernetes.io/name=authelia

# 5. Smoke test: verify OIDC login still works for immich and open-webui
```

### Rollback

If something goes wrong, revert the three files and re-apply. The old ConfigMap-with-embedded-secrets behavior will be restored immediately.

---

## Related documents

- [Security overview](security.md) — general security architecture
- [Variables and templating](variables-and-templating.md) — how `VARS.template.sh` and env var substitution work
- [K3s management](k3s-management.md) — how Kustomize overlays and HelmChart CRs are deployed
