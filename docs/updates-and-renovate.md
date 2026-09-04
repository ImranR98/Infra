# Updates and Renovate Integration

Infra uses [Renovate](https://docs.renovatebot.com/) to automatically discover and apply dependency updates across Docker images, Helm charts, and Traefik plugins referenced in the repository.

## How it works

```
renovate.json config
    │
    ▼
./infra.sh <target> update
    │
    ├── npx renovate (local mode)  →  debug JSON log
    │                                        │
    └── _apply_updates.py  ←  parses updates  ←  stdin
         │
         ▼
    Modifies source YAML files in targets/
         │
         ▼
    Checks Traefik plugins via GitHub API
         │
         ▼
    User runs: git diff → validate → commit
```

## Renovate configuration

`renovate.json` at the repo root defines what to scan and how:

### Custom managers

Five regex-based managers extract dependency information:

1. **K3s Docker images** — matches `image: <name>:<version>` patterns in K3s YAML
2. **Helm chart repositories** — matches `repository:` / `tag:` pairs (used by HelmChart CRDs with inline Docker images)
3. **Helm charts** — matches `chart:` / `repo:` / `version:` triples for full Helm chart dependencies
4. **K3s upgrade plans** — matches `version: vX.Y.Z+k3sN` in `system-upgrade` plan YAMLs, sourced from `k3s-io/k3s` GitHub releases with custom regex versioning (RC tags excluded)
5. **Compose pinned images** — matches `image: <name>:<version>` patterns in `targets/<target>/compose/compose.yaml`, but only for version-pinned tags (currentValue starting with a digit or `v`). Floating/untagged tags (`latest`, `stable`, `alpine`, bare `imranrdev/*`) are deliberately NOT matched.

Managers 1–4 target K3s YAML files (`targets/.+/k3s/.*\.yaml$`); manager 5 targets compose files (`targets/.+/compose/compose\.yaml$`). `enabledManagers: ["regex"]` ensures Renovate's built-in managers (notably docker-compose) never scan anything else.

### Compose image ownership model

Each compose image is owned by exactly one updater:

| Image tag style | Updater | Notes |
|-----------------|---------|-------|
| Pinned, mutable (`v3`, `16-alpine`, `2` — no full pin) | **Renovate** | Service carries `com.centurylinklabs.watchtower.enable=false` so watchtower stops same-tag refreshes; Renovate is the single updater. Apply via `update` then `compose restart <service>`. |
| Pinned, exact (`v0.71.0`, `0.2.5`) | **Renovate** | No label needed — watchtower only re-pulls the exact tag if re-pushed (effectively a no-op). |
| Floating (`latest`, `stable`, `alpine`) or untagged (`imranrdev/*`) | **Watchtower** | Invisible to Renovate — no regex match, so the `pinDigests` rule can never convert them to digest pins and fight watchtower. |
| Untagged inside a watchtower-excluded service (e.g. `sb25`) | **Manual** | Scanned by neither; bump the image line by hand. |
| Local-only image (no remote) | **Manual** | Untagged + excluded = invisible to Renovate. If version-pinned, the registry lookup fails harmlessly (no updates proposed); add `# PRESERVE_FULL` to make the opt-out explicit. |

### Package rules

Floating tags (`latest`, `stable`, `release`) are pinned to digests via `pinDigests: true`. This converts mutable tags into immutable content-addressable references. Only applies to K3s YAML images — compose floating tags are never matched (they are watchtower's domain).

## The update command

```bash
./infra.sh <target> update [--dry-run]
```

### Step 1: Renovate scan

Renovate runs in local mode (`--platform=local`) against the repo root. It:
- Respects `--require-config=required` (no default behavior, only what's in `renovate.json`)
- Skips onboarding (no PR creation, since this is local)
- Outputs debug JSON to a temp file

### Step 2: Apply updates

`_apply_updates.py` reads the Renovate debug log from stdin, finds the `"packageFiles with updates"` message, and processes each file with pending updates:

- For each update, it finds the `replaceString` in the source file and replaces the old version with the new one
- It respects two annotation markers:
  - `# PRESERVE_FULL` — skip this line entirely (never update)
  - `# PRESERVE_MAJOR` — skip major version bumps for this line
- Updates are deduplicated by file + dependency name

### Step 3: Traefik plugin check

After Renovate updates, the command also checks for Traefik plugin updates by:
1. Extracting plugin module references from Traefik config YAML files
2. Querying the GitHub Releases API for the latest version tag
3. Updating the version number if a newer release is found

### Dry run

With `--dry-run`, updates are printed but source files are not modified.

## Version annotations in source files

```yaml
# Example with annotations:
image: some/image:v1.2.3  # PRESERVE_FULL     ← never updated
image: other/image:v1.2.3  # PRESERVE_MAJOR   ← minor/patch only
image: another/image:v1.2.3                    ← full auto-update
```

## Post-update workflow

After running `update`:

1. Review changes: `git diff`
2. Validate: `./infra.sh <target> validate`
3. Test the deployment if possible
4. Commit the changes

For K3s plan version bumps, apply the updated plans with `./infra.sh <target> k3s deploy system-upgrade apply`, then watch the rollout with `kubectl -n system-upgrade get plans,jobs` and verify with `kubectl get nodes`. The system-upgrade-controller itself is not version-pinned: `prep.sh` applies the latest release manifests from GitHub on every deploy.

The update command is designed to be run periodically as part of routine maintenance. It handles the mechanical work of finding and applying version bumps; the human reviews and validates.
