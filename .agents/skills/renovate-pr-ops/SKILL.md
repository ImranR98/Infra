---
name: renovate-pr-ops
description: Cross-repo Renovate operations for the Infra homelab. Inventory and merge app-repo Renovate PRs (including open-but-unmerged ones), wait for their image publish jobs, manually pin the published app image digests in the Infra repo, work the Infra PRs (the manual gate), and deploy on consent. Use when asked to review or merge Renovate PRs across any repo, fix a stalled Renovate or image-publish flow, or deploy merged updates to srv0, vps0, pc, bigpc, or rpi.
---

# Renovate PR Ops

Scope: **every Renovate PR** in `INFRA_REPO` and `APP_REPOS` — not only the Infra
repo. Open PRs in app repos that Renovate has not merged are work items too
(waiting on `renovate/stability-days`, missed auto-merge, blocked, or failed).
This skill covers the app → image publish → Infra digest pin chain and the Infra
PRs that are the human gate.

## Automation model

- The scheduled `renovate-daily` CronJob is a **pure Renovate run** every six hours.
  It does not merge, wait, or notify.
- App repos extend the shared preset (`github>ImranR98/Infra//renovate-preset`).
  Renovate auto-merges non-major updates (patch/minor/digest/pin/lockfile
  maintenance) after the required `test` check. Its `renovate/stability-days`
  status is a minimum-release-age hold: while it is `pending`, do **not** merge
  early. Majors wait on the Dependency Dashboard until approved.
- The skill still merges app PRs that are ready but open: a green, non-major PR
  with `stability=success` that Renovate has not merged yet (for example the next
  six-hourly run is hours away) is merged in this run rather than left behind.
- After an app image publishes, the skill resolves the promoted GHCR digest and
  **pins it directly in the Infra repo** with `pin-app-image.sh`. This is the
  primary app-image path; it does not wait for the six-hourly run.
- The suspended `renovate-infra` CronJob remains available for non-app Infra
  updates and missed app digests. `refresh-infra.sh` is optional, not the primary
  app path.
- Infra Renovate PRs and manual digest-pin commits are **never auto-merged**.
  This skill researches, validates, and presents them; the user approves.
- App repos are remote objects. The only local checkout this skill assumes is the
  Infra repo it runs in.

## Hard rules

- **Never assume an app repo checkout exists.** Use the GitHub API for app PR
  data, checks, and merges. If a local clone is genuinely needed for research,
  clone into `tmp="$(mktemp -d)"`, use it only for that task, and remove it.
- **App PR merge:** only when the repo's required check (normally `test`;
  `validate` on config-only repos) is `success`, `renovate/stability-days` is
  `success` (or absent), the PR is mergeable, and research is clean. Merge via
  the GitHub API with `merge_method: squash` (or `gh pr merge --squash` if `gh`
  is available). Never merge an app PR by checking out and pushing an app branch.
- **Wait for the publish job.** A green `test` check only built a local image;
  the default-branch `publish` job pushes `:sha-<commit>`, verifies it, and
  promotes `:latest`. Never pin Infra after a failed or missing publish.
- **Pin from the promoted digest.** `pin-app-image.sh` requires the `:latest`
  digest to match `:sha-<merge-commit>` before editing anything. Do not hand-edit
  a digest from a PR body or an old pin.
- **Infra changes are the human gate.** A manual app digest pin is an Infra
  change like an Infra PR: show the diff and `validate` result, wait for explicit
  approval, then commit and push (unless the user pre-authorized the named
  batch).
- **Deploy on consent.** One consolidated ask per batch: targets in order, exact
  commands, verification plan, and what stays held.
- Never bypass a failing check, required check, branch protection, or the
  stability-days hold.
- Never print, commit, or inspect secret values. Do not paste full logs; extract
  error/phase lines.
- Never commit the user's in-progress Infra work; stash it for local updates and
  restore it afterwards.
- Deploy only where this checkout has access (srv0 locally, vps0 over SSH). For
  pc/bigpc/rpi, print the commands for the user to run instead.

## Autonomy contract

| Work | App non-major | App major / Tier C | Infra change (manual pin or PR) | Deploy |
|---|---|---|---|---|
| Research | quick skim | required, with evidence | required | required |
| Merge / pin | autonomous when `stability=success` | user consent | user approval | — |
| Deploy | — | — | — | user consent |

- Renovate's own auto-merge handles routine app PRs; this skill finishes the
  ready ones it left open and merges the exceptions (blocked PRs, approved
  majors, repos where Renovate could not merge).
- App majors, 0.x minors with breaking signals, and DB migrations need consent.
- Manual app digest pins and Infra PRs are presented as a batch; the user
  approves before the commit/push/merge.
- An explicit pre-authorization ("merge and deploy whatever is safe") overrides
  these gates for the named items. When unsure, escalate one tier.

Tier assignment for Infra components and app changes is documented in
[references/risk-assessment.md](references/risk-assessment.md).

## Phase 1 — Preflight

- `git status --short`; stash Infra WIP with `git stash push -m "renovate-pr-ops"`
  and restore with `git stash pop` after local Infra updates.
- `hostname` (expect srv0) and `kubectl get nodes` — the admin kubeconfig is
  root-only, so the user must have an unlock session running. App inventory,
  merges, and digest pinning work without cluster access; only the runner health
  check and deploys need the unlock.
- `git fetch origin` and confirm local `master` == `origin/master`.
- Confirm the GitHub token is available to the helpers. Do not print it.
- Ask for the vps0 SSH target (`user@host`) and repo path only when a vps0
  deploy is planned; never hardcode or assume either.

## Phase 2 — Cross-repo inventory and runner health

```bash
bash .agents/skills/renovate-pr-ops/scripts/daily-health.sh
bash .agents/skills/renovate-pr-ops/scripts/list-prs.sh --recent 24
```

`daily-health.sh` checks the scheduled `renovate-daily` CronJob. It exits 0 for
healthy/in progress/recovered, 1 for failed/stale/suspended/missing, and 2 when
it cannot determine the state. A pure Renovate run has no `==> [n/9]` markers;
read its `ERROR:`/`WARN:` lines and the Job status. A failed attempt followed by
a successful retry is `RECOVERED`; still read the failure.

`list-prs.sh` lists every open Renovate PR across Infra and the app repos with
its checks, plus recent merged Renovate PRs (default 24h) and failed
default-branch CI runs from the last 48h. Each PR line shows the check names
(usually `test`, plus `status`/`stability`/`major`). Use it to identify:
- app PRs that are ready to merge now (required check `success`, usually
  `test=success`; `validate=success` on config-only repos; `stability=success`),
- app PRs held by minimum release age (`stability=pending`) — leave them for
  Renovate and report,
- app PRs needing consent (`major=yes`),
- app PRs that are red, conflicted, or have no `test` run,
- recent app merges whose images may still be publishing,
- open Infra PRs,
- broken default-branch CI.

If a known app merge is older than the default recency window, widen it with
`--recent 48` (or more) so its publish/commit SHA is still reported. If the
runner failed, use
[references/daily-run-troubleshooting.md](references/daily-run-troubleshooting.md)
before touching PRs. If an app publish is in flight, wait for it in Phase 4.

## Phase 3 — Triage and research

Classify each open PR by repo and risk:

- **App PRs:** ready, stability-held, major/Tier C needing consent, or red/held.
  Check the app changelog/releases for breaking changes, config/env renames, and
  DB migrations. Use the GitHub API or a temporary clone for code inspection.
- **Infra PRs:** image digest pins (rollout), Helm chart/app versions, k3s Plan
  bumps. Use the risk reference.
- Record the app → image mapping and the order in which app PRs will merge.

Do not use local app paths. `list-prs.sh` already provides the PR repo, number,
head SHA, mergeable state, check/status/stability results, and recent merges.

## Phase 4 — App merges and image publishes

1. **Merge every ready app PR, including open ones Renovate left behind.**
   - Renovate may already have auto-merged routine PRs. Use the recent-merge
     section to collect their merge commit SHAs.
   - For each remaining app PR, require the repo's required check (usually
     `test=success`; `validate=success` on config-only repos),
     `stability=success`/`missing`, mergeable state, and clean research
     (non-majors are autonomous; majors/Tier C after consent). Then merge with a
     squash:
     ```bash
     # gh, when available:
     gh pr merge <n> --repo <repo> --squash --delete-branch
     # otherwise the API (token from config/VARS.env, never printed):
     curl -fsS -X PUT \
       -H "Authorization: Bearer $GITHUB_TOKEN" \
       -H 'Accept: application/vnd.github+json' \
       "https://api.github.com/repos/<repo>/pulls/<n>/merge" \
       -d '{"merge_method":"squash","sha":"<head-sha>"}'
     ```
     Verify `"merged": true`. A 405/409 means a conflict or race: leave the PR
     open and report it; do not retry blindly.
   - `stability=pending` means the minimum release age has not elapsed. Do not
     merge early; report it as held for Renovate.
   - `renovate/configure` onboarding PRs and the `dscpln-config` repo have no
     publishable image; merge them if their own checks pass, then skip the
     publish step.
   - Record each merge commit SHA (the PR's `merge_commit_sha`).
2. **Wait for every merge's publish run.**
   ```bash
   bash .agents/skills/renovate-pr-ops/scripts/wait-for-publish.sh \
     --repo <owner/repo> --sha <merge-sha>
   ```
   - `PUBLISHED`: the app image was built, verified, and promoted.
   - `NO_PUBLISH_JOB`: the repo has no `publish` job (config-only repo); nothing
     to pin.
   - `SKIPPED`/`NO_RUN`: the merge only touched ignored paths (docs,
     `.github/**`, `renovate.json`) or the workflow did not run; no image
     changed.
   - `FAILED`/`TIMEOUT`: report the failing run and continue with other apps.
     Do not pin that merge; the Infra digest stays on the last successful image.
3. **Batch and choose the newest successful publish per app repo.**
   - Merge all approved app PRs first, then wait for all publishes. This
     produces one Infra pin batch instead of one per app.
   - If several PRs in one repo published, the newest publish supersedes the
     older ones (each later commit contains the earlier change). Pin the newest
     `PUBLISHED` merge SHA per app repo.
   - If the newest merge only touched ignored paths (`SKIPPED`/`NO_RUN`) and an
     earlier merge in the same repo published, pin that earlier successful
     publish.

## Phase 5 — Pin the app image digests in Infra

Only for app repos with a `PUBLISHED` image, and only after all publishes in
the batch have settled:

```bash
bash .agents/skills/renovate-pr-ops/scripts/pin-app-image.sh \
  --repo <owner/repo> --sha <merge-sha> --validate
```

The helper:

- discovers the image name(s) from the app's workflows (or `--image`),
- resolves `:sha-<merge-sha>` from GHCR and requires `:latest` to match it
  (promotion complete) before editing,
- updates every tracked `ghcr.io/<owner>/<image>:<tag>@sha256:...` reference in
  the Infra repo (K3s templates and vps0 Compose),
- prints `UPDATED`/`ALREADY_PINNED` plus old and new digests,
- runs `bash scripts/validate.sh <target>` for each touched target with
  `--validate`.

Useful outputs and exits:

| Output | Meaning | Action |
|---|---|---|
| `UPDATED ... old=... new=...` | working tree changed | review the diff |
| `ALREADY_PINNED` | Infra already points at the promoted digest | no commit |
| `NO_IMAGE` | repo has no image or none is pinned in Infra | skip; pass `--image` if it should be pinned |
| `NO_MATCH` | image exists but not with this tag/pin shape | check `--image`/`--tag`; add the manifest pin first if new |
| `DIGEST_NOT_FOUND` / `NOT_PROMOTED` | publish has not produced/promoted the digest | wait/recheck; do not pin |
| `VALIDATE_FAILED` | the target preflight failed | hold; fix the cause, do not commit |

Options: `--dry-run` to preview, `--tag latest` (default), `--digest` to pin a
known digest, `--no-verify-latest` only for a deliberate exception, `--commit`
to stage/commit only the changed files, `--message` to set the commit subject.

Rules for this phase:

- If an open Infra `infra-digest-pin` PR already contains exactly the promoted
  digest, use the Phase 6 PR flow instead of hand-editing.
- If an open digest PR contains an older digest, the manual pin supersedes it;
  do not merge that stale PR.
- Present the combined `git diff --stat`/`git diff` and validation results.
  Wait for explicit approval, then commit and push `master`. `--commit` commits
  only the files the helper changed, so the user's other work is untouched.
- A manual pin is inert until the deploy; it is not a rollout by itself.
- Optional: after the app pins are pushed, run `refresh-infra.sh` only for
  non-app or missed updates. Do not run it while an app publish or another
  Renovate Job is in flight.

## Phase 6 — Infra PRs (human gate)

1. Triage all open Infra Renovate PRs, not only digest pins. Research charts,
   app versions, k3s Plans, and digest batches with the risk reference.
2. For each approved batch, run `bash scripts/validate.sh <target>` on the PR
   ref and present the risk, evidence, and recommendation.
3. Wait for explicit approval, then merge locally and push:
   ```bash
   git fetch origin pull/<n>/head:renovate/pr-<n>
   git checkout renovate/pr-<n>
   bash scripts/validate.sh <target>        # every target the PR touches
   git checkout master
   git merge --no-ff -m "Merge pull request #<n> from <owner>/<branch>" \
     -m "<PR title>" renovate/pr-<n>
   git push origin master
   ```
4. `infra-digest-pin` marks image pins that need a rollout. Merging is inert
   until the deploy.
5. Restore the Infra stash once the local changes are done.

## Phase 7 — Deploy (on consent)

Push `master` first so remote checkouts can `git pull`. Present one consolidated
ask, then deploy in risk order using
[references/deploy-and-verify.md](references/deploy-and-verify.md):

1. srv0: `bash scripts/deploy.sh srv0` inside an unlock session (validate →
   `srv0-base` → `srv0-apps` → helm-controller, rollout, pod, restart, and
   `/readyz` checks). The raw `helm upgrade` commands remain the fallback.
2. srv0 compose sidecars that changed (for example the public-exposure client).
3. vps0: compose `up -d <changed services>` over SSH, using the user-supplied
   target and verified repo path.
4. k3s Plan bumps (Tier C): apply `srv0-base`, then follow the upgrade-watch
   playbook.
5. pc/bigpc/rpi: emit the `git pull` + compose commands; do not attempt them.

### Derived images (nfs-server)

The nfs-server image source still lives in this repo:

- `nfs-server-src/**` → `.github/workflows/nfs-server-image.yml` (PRs build
  without pushing; master builds, verifies, promotes).

This is now a normal two-step Infra flow: merge the Dockerfile/base bump, let
the image workflow publish on master, then pin the new digest — usually the
next Renovate Infra pass opens the digest PR; otherwise update the nfs-server
pin manually from the published digest. Merge/pin, then deploy.

## Phase 8 — Verify and report

Run the verification checklist and dead-pod cleanup from the deploy reference.
Never claim success from `helm upgrade` output alone — verify the running state.

Report format:

- **Daily run** — CronJob verdict (OK/recovered/failed/stale), failed run/retry,
  and what was fixed.
- **App PRs** — merged vs held, repo/number/title, and whether Renovate
  auto-merged or the skill merged it. Call out `stability=pending` holds.
- **Published** — app, merge SHA, publish run result; note skipped/no-publish/
  failed publishes.
- **App image pinned** — app, image, old → new digest, files, `validate` result,
  commit SHA, and user approval.
- **Infra refresh** — optional `refresh-infra.sh` Job result and any new/updated
  Infra PR.
- **Infra merged** — PR number, title, targets, and user approval.
- **Deployed** — target, what changed, verification result.
- **Held** — PR plus reason and evidence; what the next run should re-check.
- **Pending commands** — for machines this agent cannot reach.
- **Alerts** — failed default-branch CI runs, failed/pending PR checks, and open
  Dependabot/OSV alerts; say "none" if clean.

## Helpers

- `scripts/daily-health.sh` — pure Renovate CronJob health.
- `scripts/list-prs.sh [--recent HOURS]` — all-repo PR inventory, recent merges,
  failed default-branch CI; shows each check name, combined `status`,
  `stability`, and `major`.
- `scripts/wait-for-publish.sh --repo R --sha S` — wait for the app `publish`
  job on a merge commit; returns `NO_PUBLISH_JOB` immediately for config-only
  repos.
- `scripts/pin-app-image.sh --repo R --sha S [--validate] [--dry-run]
  [--commit]` — resolve the promoted GHCR digest and update the Infra image
  pins; optionally validate and commit only those files.
- `scripts/refresh-infra.sh [--dry-run]` — optional on-demand Infra-only
  Renovate Job and digest-PR wait for non-app or missed updates.

All helpers use the GitHub/GHCR APIs for app data and never assume an app
checkout.
