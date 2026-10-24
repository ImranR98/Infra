# Deployment hookup (this Infra)

Skip this phase for apps deployed elsewhere. The app-side pipeline is complete
without it. This reference is the only environment-specific part of the skill.

`AGENTS.md` is the source of truth for the Infra repo's layout, deploy commands,
and safety rules. Read its targets, Renovate, and validation sections first.

## Runner

The self-hosted Renovate runner lives in two places:

- `targets/srv0/k3s-base/templates/renovate.yaml` — the CronJob (daily, 17:00
  America/Toronto). It exports `RENOVATE_REPOSITORIES` and calls the PR notifier
  with an explicit `--repo` list.
- `scripts/renovate.sh` — the local/on-demand runner; it exports the same
  repository list and notifier arguments.

Add the app repo (`<owner>/<repo>`) to:

1. `RENOVATE_REPOSITORIES` in `targets/srv0/k3s-base/templates/renovate.yaml`.
2. `RENOVATE_REPOSITORIES` in `scripts/renovate.sh`.
3. The notifier `--repo` list in both files.

The token is in `config/VARS.env` (gitignored), read by the runner as
`RENOVATE_GITHUB_TOKEN` and exported as `RENOVATE_TOKEN`. Never print it.

Required token scopes:

- `repo` — read/write repository and PRs.
- `workflow` — push `.github/workflows` changes (action pins/updates). Without
  this, Renovate logs `Workflows update rejection` and action updates abort.
- `read:packages` — only needed if Renovate must read private package metadata;
  a public GHCR package needs no `read:packages` even when its source repo is
  private.

If the runner's image or schedule changes, keep the repository list and notifier
in sync in both files.

## Deployment digest rule

`renovate.json` at the Infra repo root already has:

- a `kubernetes` manager scoped to `targets/srv0/k3s-(base|apps)/**`;
- custom regex managers for chart/image/ARG pins;
- a global `pinDigests` rule for floating tags;
- a global `docker digests` group for digest/pin refreshes;
- at least one existing per-app image digest rule.

Add a rule for the new image after the global rules so it can override the
group name:

```json
{
  "description": "<app> image digests",
  "matchDatasources": ["docker"],
  "matchPackageNames": ["/^ghcr\\.io\\/<owner>\\/<image-prefix>/"],
  "matchUpdateTypes": ["digest", "pinDigest"],
  "groupName": "<app> image digests"
}
```

Decide with the user whether to:

- use a dedicated per-app group (clear deployment PR per app), or
- leave the image in the existing global digest group (fewer, larger PRs).

The Infra repo's `automerge` is `false`; do not change that policy without
consent. Digest PRs are reviewed/merged like any other Infra PR.

## Deployment references

Find every reference and update it:

- `targets/vps0/compose/compose.yaml` — Compose images on vps0.
- `targets/srv0/k3s-apps/templates/*.yaml` — K3s workloads.
- `targets/bigpc/compose/compose.yaml`, `targets/pc/compose/compose.yaml`,
  `targets/rpi/compose/compose.yaml` — if the app is deployed there.
- docs/runbooks that pin the image or document a manual build.

Search for the old registry/namespace/image and for `image:`. Update all
production refs. Do not touch a deliberately frozen/disabled image unless the
user asks.

Public package → no pull work, regardless of repo visibility. A private repo
can publish a public package; flip it once in the package settings UI and
verify anonymous pull.

Private package → add the deployment's registry auth. K3s uses an
`imagePullSecret`; Compose uses registry login on the host. Never commit
credentials. Only choose this when the image itself must stay private.

## Branch protection and auto-merge

The app repo's Renovate auto-merge depends on GitHub settings, not just the
config file:

- `allow_auto_merge: true`.
- Required status check: the CI job name (prefer `test`).
- `delete_branch_on_merge` optional.
- Choose whether to require branches to be up to date (strict):
  - strict is safer but multiple open Renovate PRs can wait for a rebase; the
    daily runner will eventually rebase them;
  - non-strict lets independent PRs merge after their own test, with the
    post-merge CI on the default branch as the final gate.

Do not enable major auto-merge unless the app's `test` check is required and the
gate is sufficient. If the CI job is not named `test`, either rename it or set
Renovate's `statusCheckNames` to match.

`gh` may not be installed. Use the GitHub UI or the API with the existing token;
never echo the token. Example API shape:

```text
PATCH /repos/<owner>/<repo>            {"allow_auto_merge":true,"delete_branch_on_merge":true}
PUT   /repos/<owner>/<repo>/branches/<branch>/protection   (required status check: test)
```

## First run

After the app repo's CI and `renovate.json` are merged:

- Trigger a one-off run:

  ```bash
  kubectl -n base create job --from=cronjob/renovate "renovate-manual-$(date +%s)"
  ```

  The admin kubeconfig is root-only; run `bash scripts/kubeconfig-unlock.sh` in
  another terminal if needed. Alternatively run `bash scripts/renovate.sh`
  locally.

- Wait for completion and inspect the logs for:

  - `Repository started (repository=<owner>/<repo>)`
  - `Dependency extraction complete`
  - PRs for the expected dependency surfaces
  - no `Workflows update rejection`

- Expect a Dependency Dashboard issue and initial pin PRs (actions, Docker
  bases). Let their `test` job pass before merging.
- After a publish, the deployment-side image digest rule should open/refresh the
  Infra digest PR. Confirm the templates now pin the new digest.

Do not deploy from this skill. Use the normal Infra review/deploy flow; for this
repo that is the `renovate-pr-ops` skill and `AGENTS.md`/`validate.sh`.

## Skip / ask cases

- **No app repo / image built in this deployment repo:** use the deployment
  repo's build/Renovate process; don't onboard app-side.
- **Archived/frozen app:** ask whether it is still used; do not add a new noisy
  pipeline.
- **Not deployed here:** skip this phase; document the deployment-repo pattern.
- **Stale Docker Hub image after a prior GHCR migration:** deprecate, don't
  re-onboard.
- **Private package:** confirm pull auth, or make the package public and verify
  anonymous pull, before adding the digest rule. A private source repo alone
  does not require a private package.
- **Multiple deployment refs:** update all (Compose + K3s + docs); verify none
  remain.
- **Non-`latest` deployment tag:** ensure the app publish workflow produces that
  tag; the digest rule needs the tag that is actually deployed.
- **Global vs per-app grouping:** ask; both are valid depending on deployment
  batching.

## Verification

- Infra `git grep` finds no unintended old registry refs for the app.
- The app repo is in `RENOVATE_REPOSITORIES` and the notifier list.
- The dependency dashboard exists and lists the expected files.
- A test dependency bump opens a PR, runs the app `test`, and auto-merges only
  when allowed.
- A publish produces a new digest; the Infra PR updates all deployment refs.
- The deployment pulls from GHCR successfully (public anonymously; private with
  the configured auth).
