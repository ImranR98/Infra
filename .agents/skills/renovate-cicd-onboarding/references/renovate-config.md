# Renovate configuration

The Renovate file belongs to the **app repo** and must be portable. It must not
mention the deployment repo, its paths, or its owner. The deployment-side digest
rule lives in the deployment repo (see `infra-hookup.md` for this environment).

## Base config

Adapt, don't cargo-cult. Start from the app's actual ecosystems.

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "docker:pinDigests",
    "helpers:pinGitHubActionDigests",
    ":configMigration"
  ],
  "osvVulnerabilityAlerts": true,
  "dependencyDashboard": true,
  "rangeStrategy": "replace",
  "lockFileMaintenance": {
    "enabled": true,
    "schedule": ["at any time"]
  },
  "packageRules": [
    {
      "description": "Batch non-major npm updates; majors stay visible",
      "matchManagers": ["npm"],
      "matchUpdateTypes": ["minor", "patch", "pin", "digest"],
      "groupName": "npm deps (non-major)"
    },
    {
      "description": "Docker base image pins and digest refreshes",
      "matchManagers": ["dockerfile"],
      "matchUpdateTypes": ["digest", "pinDigest"],
      "groupName": "docker base images"
    },
    {
      "description": "GitHub Actions updates",
      "matchManagers": ["github-actions"],
      "groupName": "github actions"
    }
  ]
}
```

Every app repo carries `security:minimumReleaseAgeNpm` plus a top-level
`"minimumReleaseAge": "3 days"`; keep both. Do not add presets that require an
ecosystem the app does not use.

## Merge policy

This homelab does **not** use Renovate or GitHub platform automerge in app repos.
The Infra `renovate-daily` job merges every green app PR with
`scripts/merge-renovate-prs.sh` after the required `test` check is `success`
(including majors and lockfile maintenance). The helper updates behind branches
and is the only merge path, so public and private repos behave identically and
private repos do not need branch protection.

- Required: a `test` job that runs on every PR and fails on real errors.
- Do **not** add `automerge`, `platformAutomerge`, `automergeType`, or
  `automergeStrategy`; the daily helper is the gate.
- Add the repo to `APP_REPOS` in `scripts/repos.sh`; the daily job runs Renovate,
  requires `test`, and merges.
- `scripts/check-app-configs.sh` must pass: standard presets, OSV alerts,
  dependency dashboard, `rangeStrategy: replace`, `minimumReleaseAge`, and
  lockfile maintenance where a lockfile exists.
- Only proceed with majors when [the test gate](test-gate.md) is sufficient.

## Grouping

- Group non-major updates per ecosystem to reduce noise.
- Keep majors separate by default. Group known monorepos (e.g. a framework and
  its plugins) when Renovate recognizes them, but keep the group reviewable.
- Group Docker base-image digest refreshes separately from app dependency
  updates.
- Group GitHub Actions updates so action pins/updates do not flood the queue.
- Do not group unrelated runtime majors just to reduce PR count.

## Runtime/version strategy

- **Node:** prefer a rolling LTS base (`node:lts-*`) pinned by digest; CI uses
  the same selector (for example `node-version: lts/*`). This makes LTS line
  transitions arrive as digest PRs and tests run on the new LTS.
- If the app cannot run on current LTS (native modules, vendor base OS), pin an
  explicit major and keep that major's updates manual; document why. Do not use
  a floating `latest`/`node` tag in production.
- **Python/Go/Rust/Java:** prefer the ecosystem's version file (`.python-version`,
  `go.mod`, `rust-toolchain.toml`, etc.) so Renovate and CI agree. If the
  Dockerfile carries a different version, align them or document the split.
- Align `engines`, CI, Dockerfile, and type packages; drift hides breakage.
- Docker base majors: if using a rolling LTS tag, majors are digest updates and
  can auto-merge. If using an explicit major tag, a major bump is a real
  runtime change; gate it with the test suite or keep it manual.

## Custom managers

Only add a custom manager for a dependency a standard manager cannot see. Keep
the regex narrow and validate it with a local lookup.

### Dockerfile ARG pinned to GitHub releases

```json
{
  "customType": "regex",
  "description": "upstream tool version baked into the image",
  "managerFilePatterns": ["/^Dockerfile$/"],
  "matchStrings": ["ARG TOOL_VERSION=(?<currentValue>\\d+\\.\\d+\\.\\d+)"],
  "depNameTemplate": "owner/tool",
  "datasourceTemplate": "github-releases",
  "versioningTemplate": "semver",
  "extractVersionTemplate": "^v(?<version>\\d+\\.\\d+\\.\\d+)$"
}
```

### Version variable in a build script

```json
{
  "customType": "regex",
  "description": "upstream release downloaded by the build script",
  "managerFilePatterns": ["/^build\\.sh$/"],
  "matchStrings": ["TOOL_VERSION=\"(?<currentValue>\\d+\\.\\d+\\.\\d+)\""],
  "depNameTemplate": "owner/tool",
  "datasourceTemplate": "github-releases",
  "versioningTemplate": "semver"
}
```

### Wrapper build arg

```json
{
  "customType": "regex",
  "description": "upstream binary tag passed as a build arg",
  "managerFilePatterns": ["/^build\\.sh$/"],
  "matchStrings": ["LATEST_TAG=\"?(?<currentValue>v?\\d+\\.\\d+\\.\\d+)"],
  "depNameTemplate": "owner/upstream",
  "datasourceTemplate": "github-releases",
  "versioningTemplate": "semver"
}
```

For any custom manager:

- escape regex metacharacters correctly;
- preserve the prefix/suffix that must stay in the file (for example a leading
  `v` outside the capture);
- test the replacement with `renovate --platform=local --dry-run=lookup`;
- avoid matching comments or example files;
- do not pin system packages that the distro does not version reliably.

## Nested manifests and non-package dependencies

- `config:recommended` detects multiple `package.json`/lockfile pairs, Python
  requirements, Go modules, pre-commit hooks, and similar files.
- Do not ignore nested client/server/scripts directories or a Python subproject
  just because the main app is one language.
- Do not ignore `.pre-commit-config.yaml`, `.tool-versions`, `.nvmrc`, or
  `mise.toml`; they are dependency surfaces.
- `ignorePaths` is for examples, fixtures, generated files, and frozen demos —
  not for real manifests. If an example Compose file only has floating `latest`
  image tags, ignoring it avoids perpetual pin PRs.

## Schedules and the runner

- Match the app's Renovate schedule to the runner's actual run time. A
  `before 6am` window is useless if the only self-hosted run is at 17:00.
- `lockFileMaintenance` defaults to a Monday early-morning window; if the runner
  does not run then, set `schedule: ["at any time"]`.
- If the runner is the Mend app, its schedule may differ; use a schedule that
  actually fires.
- Do not assume a daily runner if you are configuring an on-demand one.

## GitHub Actions

- `helpers:pinGitHubActionDigests` pins `uses:` entries by digest. Renovate needs
  a token with the `workflow` scope (or a GitHub App with workflow write) to push
  those changes.
- If workflow updates are rejected, the token lacks that permission; do not
  disable action updates to hide it.
- Pin actions after the first run; keep the version comment so reviewers can
  read them.

## Validate and dry-run

```bash
npx --yes -p renovate renovate-config-validator --strict renovate.json
npx --yes -p renovate renovate --platform=local --dry-run=lookup
```

Check:

- every surveyed manifest/manager is detected;
- no unexpected `skipReason` (unpinned requirements, invalid versions, ignored
  paths);
- custom managers produce the expected replacement;
- Docker base images are pinned;
- the dependency dashboard will list the app's files.

## Common pitfalls

- Floating `FROM node` / `FROM ubuntu` — pin a version and digest.
- `npm install`/`npm i` in Dockerfiles — use the lockfile (`npm ci`).
- Build-time `curl …/latest` — pin an ARG and track it.
- Version tags used by deployments but not published by CI — preserve the tag
  scheme.
- Image name inferred from repo name — discover it.
- Docker Hub references in comments/docs/scripts — they are not dependencies to
  Renovate, but they are migration work.
- Multiple Dockerfiles — ask which one is production.
- Archived/frozen app — ask before onboarding; do not create a noisy pipeline
  for a dead service.
- Repo visibility does not dictate package visibility. A private repo can have
  a public GHCR package (preferred for generic images); verify anonymous pull
  rather than assuming either state.
- Major auto-merge without a required check — never.

## When not to use

- The repo is archived/frozen and the user does not want automation.
- The image has no app repo or is built in the deployment repo; use that
  repo's build/Renovate process instead.
- The project is a library/package rather than an image; adapt the publish
  stage instead of forcing a container.
- The app cannot run tests in the available CI and the user declines a broader
  test/refactor effort; keep majors manual and document the gap.
