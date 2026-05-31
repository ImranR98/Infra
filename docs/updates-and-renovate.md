# Updates and Renovate Integration

Atlas uses [Renovate](https://docs.renovatebot.com/) to automatically discover and apply dependency updates across all Docker images, Helm charts, and Traefik plugins referenced in the repository.

## How it works

```
renovate.json config
    │
    ▼
./atlas.sh <target> update
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

Three regex-based managers extract dependency information from K3s YAML files:

1. **Docker images** — matches `image: <name>:<version>` patterns
2. **Helm chart repositories** — matches `repository:` / `tag:` pairs (used by HelmChart CRDs with inline Docker images)
3. **Helm charts** — matches `chart:` / `repo:` / `version:` triples for full Helm chart dependencies

All managers target K3s YAML files (`targets/.+/k3s/.*\.yaml$`).

### Package rules

Floating tags (`latest`, `stable`, `release`) are pinned to digests via `pinDigests: true`. This converts mutable tags into immutable content-addressable references.

## The update command

```bash
./atlas.sh <target> update [--dry-run]
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

## FRPC version synchronization

When the FRPC Docker image is updated, the update command prints a reminder:

```
FRPC was updated. Run the following to build the matching frps-with-multiuser image:
  ./atlas.sh <target> compose build-frps <frps target>
```

This is necessary because the FRP client and server must run the same protocol version. See [compose-management.md](compose-management.md) for the build-frps workflow.

## Post-update workflow

After running `update`:

1. Review changes: `git diff`
2. Validate: `./atlas.sh <target> validate`
3. Test the deployment if possible
4. Commit the changes

The update command is designed to be run periodically as part of routine maintenance. It handles the mechanical work of finding and applying version bumps; the human reviews and validates.
