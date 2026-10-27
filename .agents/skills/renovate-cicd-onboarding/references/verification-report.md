# Verification and report

Verify the actual flow, not just the files. Record evidence (commands and
results), never secrets or private data.

## App repo

- [ ] Working tree clean except intended changes; branch/PR opened.
- [ ] Default branch detected correctly; CI trigger/publish use it.
- [ ] `npm ci` (or ecosystem equivalent) passes from the lockfile.
- [ ] Lint/typecheck/build pass.
- [ ] Tests pass; record pass/skip counts and duration.
- [ ] No silently skipped tests; missing tools fail.
- [ ] Production image builds.
- [ ] Image smoke passes (HTTP/CLI/fixture, required tools, production deps).
- [ ] Existing tests were reused, or new tests cover the agreed critical paths.
- [ ] `renovate-config-validator --strict` passes.
- [ ] Local `renovate --platform=local --dry-run=lookup` detects every surveyed
      dependency surface; no unexpected skips.
- [ ] `git diff --check`; no secrets, generated files, or unrelated changes.

## PR and publish

- [ ] PR `test` check is green.
- [ ] The required check name matches branch protection.
- [ ] Merge (by the normal policy) triggers the `publish` job.
- [ ] `publish` only runs on the default branch, not PRs.
- [ ] Images push to GHCR with the expected names/tags.
- [ ] Digest is recorded in the summary/artifact.
- [ ] Public repo: `docker pull ghcr.io/<owner>/<image>:<tag>` works anonymously.
- [ ] Private repo: the deployment's auth works; no credentials committed.
- [ ] Old registry push/login paths are gone (or deliberately retained with a
      reason).
- [ ] Deployment tag scheme is preserved.

## Renovate behavior

- [ ] The runner sees the repo; logs show extraction and PRs.
- [ ] Dependency Dashboard exists.
- [ ] At least one dependency PR opens; its `test` runs.
- [ ] Auto-merge is enabled only where the gate allows.
- [ ] Majors are manual if the gate is insufficient.
- [ ] No `Workflows update rejection`; the token has `workflow` scope if action
      pinning/updates are configured.
- [ ] Initial pin PRs (actions/base images) are merged after tests.
- [ ] A subsequent publish produces an image digest PR in the deployment repo.

## Deployment repo

- [ ] App repo added to the runner and notifier lists.
- [ ] The first-party `ghcr.io/imranr98/*` digest group covers the new image (no per-app rule).
- [ ] Every deployment ref updated (Compose, K3s/Helm, docs).
- [ ] No unintended old registry refs remain.
- [ ] First-party vs third-party digest grouping documented (no per-app groups).
- [ ] Public/private pull path verified.
- [ ] Frozen/archived/Infra-built images untouched unless requested.
- [ ] No deployment performed by this skill; the normal consent/deploy flow is
      next.

## Report template

```text
# Renovate/CI onboarding — <app>

## Summary
- Repo:
- Default branch:
- Shape:
- Production image(s) / tags:
- Registry / visibility:
- Runtime(s):
- Gate decision (majors auto-merge? yes/no/why):

## Inventory
| Surface | Current | Manager/custom manager | Notes |
|---|---|---|---|

## Tests
- Existing tests reused:
- Tests added (file/level/why):
- Image smoke:
- Prerequisites/tools:
- Pass/skip counts and duration:

## CI and publish
- `test` job / required check:
- `publish` job / tags / digest:
- Existing workflows preserved:
- Native/system tools:
- Architecture:

## Registry
- Old → new refs:
- Tag scheme:
- Public/private and pull auth:
- Docker Hub deprecation step (manual):

## Deployment
- Runner files updated:
- Digest rule:
- Deployment refs updated:
- Grouping decision:
- First-run evidence:

## Deviations
| Phase | Default | Deviation | Reason | Approval | Residual risk |
|---|---|---|---|---|---|

## Manual steps still required
- (branch protection, package visibility/auth, Docker Hub deprecation,
  deployment merge/deploy, token scope, etc.)

## Residual risks
- (untested paths, wrapper/binary majors, native/OS constraints, archived
  services, etc.)
```

## Evidence rules

- Quote the command and the result; not the secret.
- If something was not run, say so; do not imply verification.
- If a test was skipped, include the reason and whether it affects the gate.
- If a deviation was approved, link the decision to the report row.
- If the app is archived/frozen/no-repo/Infra-built, report the decision and stop
  rather than manufacturing a pipeline.

## Final handoff

The onboarding is complete when:

- the app-side pipeline is green and portable,
- the deployment hookup (if applicable) opens a digest PR,
- the report lists remaining consent steps,
- and the app can receive a dependency update without manual file edits.

Deploying the resulting image is a separate, consent-gated action.
