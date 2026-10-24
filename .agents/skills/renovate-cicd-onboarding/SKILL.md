---
name: renovate-cicd-onboarding
description: Onboard an app repo into Renovate + GitHub Actions CI/CD. Use when asked to automate dependency updates for an app, add CI/CD or tests to gate major updates, migrate an app from Docker Hub to GHCR, or hook a new app into a deployment repo's Renovate runner and image-digest updates. Surveys dependency surfaces and test coverage, adds or strengthens tests, publishes images to GHCR, adds Renovate config, and wires the app into the deployment-side digest rule.
---

# Renovate + CI/CD onboarding

Onboard **one app at a time** into a dependency-update pipeline:

```
dependency release
  → Renovate (external runner) → app PR
  → app `test` job (required) → auto-merge
  → app `publish` job → GHCR image + digest
  → deployment-repo Renovate → digest PR
  → human merge → deploy
```

This skill covers the **app side** plus an optional **deployment hookup**. The app
side must remain portable: anyone using GitHub, Renovate, and GHCR should be able
to reuse it. The deployment hookup is specific to the environment you are in and
is isolated in [references/infra-hookup.md](references/infra-hookup.md).

The skill builds the pipeline. It does **not** merge or deploy. Once the pipeline
exists, dependency PRs are handled by the normal review/merge policy (for this
Infra, the `renovate-pr-ops` skill).

## Judgment over ritual

This is a default playbook, not a contract. Apps differ in stack, test maturity,
registry, deployment model, and risk. Read the app first; prefer its existing
tools and conventions. If a default does not fit, say so and propose an
alternative instead of forcing the phase.

### Non-negotiable

- Never leak or commit secrets; never read runtime config/state.
- Never merge or deploy; open PRs and report. Deployment stays consent-gated.
- Never enable major auto-merge without a sufficient test gate and a required
  status check. If the gate is weaker, leave majors manual and say why.
- Never hardcode this deployment repo's paths, targets, or owner in app-side
  files.
- Never destroy user work, existing CI, or the old registry without consent.
- Never claim verification that was not run.

### Defaults (adapt with a reason)

- Phase order and artifacts.
- Test framework, test shape, and coverage target.
- Dockerfile/CI structure and image architecture.
- Registry: GHCR by default for this pipeline; another registry is acceptable
  if Renovate can track it and the user agrees.
- Runtime strategy: rolling LTS + digest by default; explicit major + manual
  gate when the app genuinely requires it.
- Renovate grouping, schedule, and auto-merge policy.
- Deployment hookup: optional; skip when the app is not deployed here.
- Multi-package/multi-image handling.

### Divergence threshold

Ask before diverging when the change affects:

- test-gate strength or major auto-merge,
- registry, image consumers, or pull access,
- deployment manifests or runtime behavior,
- security, irreversible actions, or broad refactors,
- an archived/frozen/no-repo/Infra-built image.

Proceed and record when the difference is mechanical and low-risk:

- a different test command/framework that matches the app,
- a different CI step order or build tool,
- a Dockerfile style that fits the stack,
- an image/package name that is already established.

### Deviation protocol

When asking, present:

1. Default the skill recommends.
2. App-specific constraint or evidence.
3. Proposed alternative.
4. Effect on the test gate, deployment, or consumers.
5. Residual risk and what stays manual.
6. Recommendation.

Record every approved or material deviation in the final report:

```text
| Phase | Default | Deviation | Reason | Approval | Residual risk |
```

If a phase is not applicable, mark it N/A with a reason instead of silently
skipping it.

## Inputs and confirmation

Required:

- A git URL or a local clone path.

Establish or confirm:

- default branch (`main`, `master`, or other),
- actual image name(s) and tag scheme,
- current registry and whether the repo is public or private,
- deployment repo/path and where the image is referenced,
- target architecture(s) (`linux/amd64`, arm64, multi-arch),
- existing CI, tests, and registry workflows,
- whether adding tests may require production-code refactors,
- auto-merge policy for majors.

Never ask for tokens. Use existing GitHub auth or the token already configured
for the Renovate runner; never print it.

## Default path

Skip or audit any phase that is already done. Present the inventory and proposed
shape before large test or registry changes.

### Phase 0 — Preflight

- Check repo cleanliness; stash/ask about WIP; create a working branch.
- Detect the actual default branch and remote.
- Check repo visibility (public/private), license, archived/frozen status.
- Check available tooling: git, container engine, language runtime, `gh`/API,
  `actionlint`/`yamllint`/`shellcheck` when present.
- Read the app's README/AGENTS/CI before assuming layout.
- If the image has no app repo, is built in the deployment repo, or is
  archived/frozen, stop and ask before onboarding.

### Phase 1 — Survey

Run:

```bash
bash .agents/skills/renovate-cicd-onboarding/scripts/survey-repo.sh <repo-path>
```

Then inspect manually. Build an inventory of:

- app shape and entry points,
- default branch and deployable image(s),
- Dockerfile(s) and which one is production,
- runtime/version files and package managers,
- lockfiles and nested manifests,
- base images, digest/tag pins, `ARG` downloads,
- system packages/PPAs/Docker-CLI/curl installs,
- GitHub Actions, pre-commit hooks, and other non-package deps,
- test command, framework, skips, prerequisites, and flakiness,
- current registry and every image reference (including comments/scripts/docs),
- deployment refs and tag scheme.

Use [references/survey-checklist.md](references/survey-checklist.md).

Output: a short inventory table plus gaps and a proposed app shape. This is the
point to surface divergences, not after rewriting the CI.

### Phase 2 — Test gate

Assess whether existing tests can gate majors:

- Build/install must pass.
- Primary behavior must be exercised (unit/API/e2e as appropriate).
- The production image must build, start, and pass a smoke check.
- No silently skipped tests; missing prerequisites fail.
- A single smoke or `--version` is not enough for an application. For a thin
  upstream-binary wrapper, say so and keep majors manual.

Reuse passing tests; do not rewrite them just to match a template. A placeholder
`test` script that exits 1 is not a test suite.

If tests are absent or insufficient, add a harness and tests for the critical
paths. Keep production refactors minimal and ask before broad changes. Use
[references/test-gate.md](references/test-gate.md).

### Phase 3 — CI and publish

Add or extend `.github/workflows/ci.yml`:

- `test` job: install, lint/typecheck/build, tests, no-skip enforcement, and a
  production-image smoke. Make it the required check.
- `publish` job: only on the default branch, `needs: test`, GHCR login with
  `GITHUB_TOKEN`, `packages: write`, image tags that match the deployment,
  digest output, and a concurrency group.

If the app uses another CI, port the same split; do not force GitHub Actions if
the environment cannot support it. If no Dockerfile exists, add one appropriate
to the stack.

Use [references/github-actions.md](references/github-actions.md). Your CI must
not reference this deployment repo.

### Phase 4 — Renovate

Add `renovate.json` at the repo root (or `.github/renovate.json`, not both):

- `config:recommended`, digest pinning, action pinning, OSV alerts, dependency
  dashboard, lockfile maintenance, release-age waiting where it fits.
- Group non-major updates; keep majors separate/visible.
- Auto-merge only when the test gate is sufficient and the required check is
  configured. Otherwise non-major only, or no auto-merge.
- Custom managers only for real non-standard pins (build-time `ARG` downloads,
  version strings in scripts, wrapper binaries).
- Runtime strategy: prefer a rolling LTS tag + digest; use an explicit major
  with a manual gate only when necessary.
- Do not ignore nested manifests, pre-commit hooks, or Python/other subprojects
  without a reason.

Validate and dry-run before pushing:

```bash
npx --yes -p renovate renovate-config-validator --strict renovate.json
npx --yes -p renovate renovate --platform=local --dry-run=lookup
```

Use [references/renovate-config.md](references/renovate-config.md).

### Phase 5 — Registry migration (if needed)

If the app publishes to Docker Hub, migrate to GHCR:

- search the app and deployment repos for every old reference,
- preserve image names and tag schemes,
- update Dockerfiles, READMEs, scripts, Compose/Helm/K8s, and CI,
- add GHCR login/push, remove Docker Hub login/push,
- public repo → public GHCR package (no pull auth needed),
- private repo → private package (deployment auth or make the package public;
  ask),
- deprecate the old Docker Hub repository; do not delete it without consent.

Use [references/ghcr-migration.md](references/ghcr-migration.md).

### Phase 6 — Deployment hookup (optional)

Only when the app is deployed in this environment, and only after the app-side
flow works. Add the repo to the Renovate runner, add the image-digest rule,
update every deployment reference, and verify the first run.

Use [references/infra-hookup.md](references/infra-hookup.md). Skip this phase for
apps deployed elsewhere and document the deployment-repo pattern instead.

### Phase 7 — Verify and report

- App: tests (record pass/skip), lint/build, image build + smoke.
- Renovate: validator and local lookup; every surface detected; no unexpected
  skips; custom managers produce updates.
- PR: `test` job green; merge; `publish` pushes the expected GHCR tags/digest.
- Deployment: Renovate sees the repo, dashboard exists, digest PR opens, no old
  registry refs remain. Do not deploy.
- Report changes, tests, gate decisions, registry mapping, deviations, manual
  steps, and residual risk.

Use [references/verification-report.md](references/verification-report.md).

## Stop and ask

Stop and bring it to the user when:

- there is no Dockerfile, or more than one plausible production Dockerfile;
- the image name or tag scheme cannot be confirmed;
- the repo is archived/frozen, the image is built in the deployment repo, or
  there is no matching app repo;
- the app has no tests and is hard to test (GUI, daemon, hardware, external
  service);
- a runtime major bump may break native modules or the base OS;
- the registry migration affects private/public access or consumers;
- the deployment has multiple refs or unusual auth;
- existing CI/registry behavior conflicts with the new flow;
- tests need credentials, live services, or a broad refactor;
- major auto-merge would be enabled without a meaningful gate.

For each, present the default, the constraint, the alternative, the gate impact,
and the residual risk. Do not silently skip.

## References

- [Survey checklist](references/survey-checklist.md)
- [Test gate](references/test-gate.md)
- [Renovate config](references/renovate-config.md)
- [GitHub Actions](references/github-actions.md)
- [Docker Hub → GHCR](references/ghcr-migration.md)
- [Deployment hookup](references/infra-hookup.md)
- [Verification and report](references/verification-report.md)
- [Survey script](scripts/survey-repo.sh)
