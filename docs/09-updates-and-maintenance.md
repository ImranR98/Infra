# 9 &mdash; Updates and Maintenance

## Overview

Atlas automates dependency scanning and version updates using a combination
of [Renovate](https://docs.renovatebot.com/) (an open-source dependency
update tool) and a custom Python script. The system detects outdated Docker
images, Helm chart versions, and Traefik plugin versions across all YAML
files in the repository.

## Update architecture

```
┌─────────┐     ┌──────────────┐     ┌──────────────────┐     ┌──────────┐
│ renovate│────►│ debug log    │────►│ _apply_updates.py│────►│ updated  │
│ scan    │     │ (JSON)       │     │ (parse + apply)  │     │ YAML     │
└─────────┘     └──────────────┘     └──────────────────┘     └──────────┘
```

1. **Renovate** scans the repository using regex managers configured in
   `renovate.json`.
2. The debug output (JSON lines) is captured to a temp file.
3. **`_apply_updates.py`** parses the JSON, finds files with pending
   updates, and applies version/digest changes directly to the YAML source
   files.
4. The user reviews changes with `git diff` and runs `validate`.

## Running updates

```bash
./atlas.sh <target> update         # Apply updates
./atlas.sh <target> update --dry-run  # Preview only
```

## Renovate configuration (`renovate.json`)

The Renovate configuration defines three regex-based custom managers:

### 1. Docker image references in K3s YAML

```json
"matchStrings": [
  "image:\\s*(?<depName>[^\\s@:\"']+):(?<currentValue>[^\\s@:\"'#]+)(?:@sha256:\\S+)?"
]
```

Matches lines like:
```yaml
image: traefik:v3.4.0
image: nginx:latest@sha256:abc123...
```

Uses the Docker datasource and versioning scheme. This covers inline
container images in Kubernetes manifests.

### 2. Helm chart references in HelmChart resources

```json
"matchStrings": [
  "chart:\\s*(?<depName>\\S+)\\s*\\n(?:[^\\n]*\\n){0,5}?\\s*repo:\\s*(?<registryUrl>\\S+)\\s*\\n(?:[^\\n]*\\n){0,10}?\\s*version:\\s*(?<currentValue>\\S+)"
]
```

Matches the K3s HelmChart CRD structure:
```yaml
spec:
  chart: cert-manager
  repo: https://charts.jetstack.io
  version: 1.20.2
```

Uses the Helm datasource and semver versioning.

### 3. Docker image references via repository + tag

```json
"matchStrings": [
  "repository:\\s*(?<depName>\\S+)\\s*\\n(?:[^\\n]*\\n){0,10}?\\s*tag:\\s*(?<currentValue>\\S+)"
]
```

Matches YAML patterns where image and tag are separate fields (e.g., in
some Helm values or custom resources).

### Floating tag pinning

A package rule pins floating tags (`latest`, `stable`, `release`) to
digests:

```json
"packageRules": [{
  "matchCurrentValue": "^(latest|stable|release)$",
  "pinDigests": true
}]
```

This replaces `image:latest` with `image:latest@sha256:...` for
reproducibility.

## The `_apply_updates.py` script

This Python script (`commands/_apply_updates.py`) reads Renovate's debug log
from stdin and applies updates to files:

### Parsing

1. Reads input line by line until finding a log entry containing
   `"packageFiles with updates"`.
2. Extracts the `config` map from that entry, which contains file paths
   keyed by manager, each with a list of dependency entries.
3. Filters entries to only those with non-empty `updates` lists.
4. Optionally filters by target (only processes files under
   `targets/<target>/`).

### Applying updates

For each dependency with updates:
1. Takes the first update from the `updates` array.
2. Locates the original string (`replaceString`) in the file.
3. Replaces `currentValue` with `newValue`.

### Preservation annotations

Two inline annotations control whether updates are skipped:

| Annotation | Behavior |
|------------|----------|
| `# PRESERVE_FULL` | Skip ALL updates for this line |
| `# PRESERVE_MAJOR` | Skip only major version bumps |
| `# PRESERVE_MAJOR` + `# PRESERVE_FULL` | Same as `# PRESERVE_FULL` |

Usage in YAML:
```yaml
image: some/image:v1.2.3  # PRESERVE_MAJOR
```

The script scans the line containing the match for these annotations before
applying changes. `updateType` is checked for `"major"` to determine if a
version bump is major.

### Floating tag digest pinning

When `currentValue` is `latest`, `stable`, or `release` and a `newDigest`
is available, the script appends `@sha256:<digest>` to the new value. This
complements the Renovate `pinDigests` rule at the script level.

## Traefik plugin updates

After Renovate processing, `update.sh` also checks Traefik plugins:

1. Extracts plugin module references from compose and K3s Traefik configs.
2. For each plugin, queries the GitHub Releases API to find the latest tag.
3. If a newer version exists, updates the version in the config file.
4. Uses a temporary file and `cmp` to detect changes, avoiding unnecessary
   writes.

## FRPC/FRPS version synchronization

If the Renovate scan updates the `fatedier/frpc` image, `update.sh` prints
a reminder:

```
FRPC was updated. Run the following to build the matching frps-with-multiuser image:
  ./atlas.sh <target> compose build-frps <frps target>
```

This is necessary because the FRP server and client versions must match.
The `compose build-frps` command builds a custom FRPS Docker image with the
same version as the updated FRPC.

## Post-update workflow

After running `update`:

1. Review changes:
   ```bash
   git diff
   ```

2. Validate everything:
   ```bash
   ./atlas.sh <target> validate
   ```

3. If everything is clean, redeploy:
   ```bash
   ./atlas.sh <target> compose install    # Compose targets
   ./atlas.sh <target> k3s group base apply  # K3s base
   ./atlas.sh <target> k3s group apps apply  # K3s apps
   ```

## Backups

The `compose backup-state` command creates point-in-time archives of the
compose runtime state. See [Commands Reference](05-commands-reference.md#compose-backup-state)
for usage.

### Backup retention

Backups are automatically pruned based on the `BACKUP_RETENTION` variable
(default: 1). Old backup files matching `<target>-backup-*.tar` are deleted,
keeping only the most recent N.

### Remote backup

Backups can be pulled over SSH from a remote machine. The remote mode SSHes
into the target, runs `backup-state` in streaming mode, and saves the tar
locally. This is useful for backing up machines that don't have local
storage for backup archives.

## Docker image cleanup

The `compose old-images` command lists Docker images older than 60 days.
This helps identify images that can be pruned:

```bash
./atlas.sh <target> compose old-images
# Review output, then optionally prune:
docker image prune -a
```

## Renovate cache

The `cache/` directory stores Renovate and containerbase caches to speed up
subsequent scans. This directory is gitignored.
