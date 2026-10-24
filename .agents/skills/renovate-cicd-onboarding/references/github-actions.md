# GitHub Actions

Use GitHub Actions by default because the target pipeline uses GHCR and
Renovate's GitHub integration. If the app lives in another CI, port the same
split (`test` gate + `publish` gate) rather than forcing GitHub.

The app-side workflow must not reference the deployment repo, its targets, or
its owner. Use `github.repository_owner` for the image namespace.

## Detect the default branch

`on.push.branches` and the publish `if` must name the repo's actual default
branch. Do not assume `main`; some repos use `master`. The workflow can still
run `pull_request` for all branches.

## Skeleton

```yaml
name: CI

on:
  push:
    branches: [<default-branch>]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: <timeout>
    steps:
      - uses: actions/checkout@v4

      # Match the production runtime. For a Node image using node:lts-*,
      # use lts/*; for an explicit major, use that major; for Python/Go/etc.
      # use the ecosystem's setup action and lockfile.
      - uses: actions/setup-node@v4
        with:
          node-version: lts/*
          cache: npm

      - name: Install system/native test tools
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            <packages needed by tests, native modules, media tools>

      - run: npm ci
      - run: npm run lint --if-present
      - run: npm run typecheck --if-present
      - run: npm run build --if-present

      - name: Test
        run: |
          set -o pipefail
          npm test 2>&1 | tee test-output.log

      - name: Reject skipped tests
        run: |
          if grep -q '# SKIP' test-output.log; then
            echo "::error::Tests were skipped; install the missing tool or fix the test."
            grep '# SKIP' test-output.log
            exit 1
          fi

      # Optional: smoke a nested Python/other subproject if it is part of the
      # app's build or deploy surface.

      - uses: docker/setup-buildx-action@v3

      - name: Build production image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: <Dockerfile>
          platforms: linux/amd64
          push: false
          load: true
          tags: <app>:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke production image
        run: bash scripts/smoke-image.sh <app>:ci

  publish:
    needs: test
    if: >-
      github.ref == 'refs/heads/<default-branch>' &&
      (github.event_name == 'push' || github.event_name == 'workflow_dispatch')
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      packages: write
    concurrency:
      group: publish-<app>
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Resolve image tags
        id: images
        run: |
          set -euo pipefail
          owner="$(echo "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
          {
            echo "tags<<EOF"
            echo "ghcr.io/${owner}/<image>:latest"
            # Add the deployment's version tag or an immutable tag if needed.
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          file: <Dockerfile>
          platforms: linux/amd64
          push: true
          tags: ${{ steps.images.outputs.tags }}
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Record digest
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
          TAGS: ${{ steps.images.outputs.tags }}
        run: |
          set -euo pipefail
          [ -n "$DIGEST" ] || { echo "no image digest" >&2; exit 1; }
          printf 'image digest: %s\n' "$DIGEST" | tee image-digest.txt
          printf '%s\n' "$TAGS" >> image-digest.txt
          {
            echo "## Published image"
            echo
            echo "Digest: \`${DIGEST}\`"
            echo
            echo '```'
            printf '%s\n' "$TAGS"
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"

      - uses: actions/upload-artifact@v4
        with:
          name: image-digest-${{ github.sha }}
          path: image-digest.txt
          if-no-files-found: error
          overwrite: true
```

## Public vs private

Package visibility is independent of repository visibility. A private repo can
publish a public package; the source stays private while the image is pulled
anonymously.

- Public repo → package is public by default. No pull secret/imagePullSecret is
  needed; do not add registry-auth work.
- Private repo → package defaults to private. Prefer making it public when the
  image is generic: the flip is one-time and irreversible, and removes all
  deployment auth. Use a private package + deployment auth only when the image
  itself must stay private. If the available token cannot change visibility,
  ask the user to use the package settings UI. Never commit credentials.

See [ghcr-migration.md](ghcr-migration.md#making-a-private-repo-package-public)
for the UI/API steps and the anonymous-pull verification.

## Tag schemes

Read the deployment refs before choosing tags:

- `latest` only is fine for a normal service.
- Some images are deployed by a version tag or a release tag; publish that tag
  too, or the deployment cannot update.
- Wrapper images may publish `latest` + an upstream version tag.
- Do not overwrite an immutable deployment tag with a moving build; ask if the
  scheme is unusual.

## Multiple images/packages

- Build each deployable image; do not publish an auxiliary Dockerfile by
  accident.
- For a monorepo/client-server, run installs/tests in every package and build
  the client before the image.
- Use a matrix if the images are genuinely independent; otherwise sequential
  steps are easier to read.
- Publish one digest artifact per image.

## Native modules and system tools

- Install native build tools (`python3`, `make`, `g++`, `build-base`) in CI when
  the lockfile needs them.
- Keep the production image's runtime base separate from the build stage; do not
  ship compilers unless the app needs them.
- If the Dockerfile installs Docker CLI, veracrypt, PPA packages, or other
  system tools, the smoke test should verify them. Ask before changing the base
  OS.

## Existing workflows

- Do not replace unrelated workflows (issue automation, icon validation,
  release jobs). Add a new workflow or extend the existing one.
- Renovate should manage their `uses:` entries; keep the `workflow` token scope
  so action updates can be pushed.
- If an existing workflow already publishes, audit it first; do not create a
  second publisher racing the same tags.

## Architecture and caching

- Default `linux/amd64` only if the deployment is amd64.
- For arm64/multi-arch, use buildx/QEMU or native runners and verify the
  Dockerfile's downloaded binaries support the target architecture.
- Cache dependencies and Docker layers; keep the test job under its timeout even
  on a cold cache.
- Serialize publishes with a concurrency group so `latest` cannot race.

## Action pinning

- Start with major tags; Renovate's `helpers:pinGitHubActionDigests` will pin
  them by digest after onboarding.
- Keep the version comment.
- Never disable action updates because a token lacks `workflow`; fix the token.
- Third-party actions are dependencies too.

## When not to use GitHub Actions

- The repo is not on GitHub; port the test/publish split to the native CI.
- The deployment registry is not GHCR and the user wants to keep it; adapt the
  login/push while keeping the same gate.
- The app is a library/CLI with no image; publish the artifact/package instead.
- The repo is archived/frozen; ask before adding automation.

## App-side boundary

Nothing in this workflow should mention the deployment repo's paths, targets,
Helm values, or owner-specific hostnames. The app publishes an image and a
digest; the deployment repo consumes it.
