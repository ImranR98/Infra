---
name: renovate-pr-ops
description: Cross-repo Renovate operations for the Infra homelab. Triage and merge app-repo Renovate PRs, wait for their image publish jobs, refresh the Infra Renovate run so new digest PRs appear, work the Infra PRs (the manual gate), and deploy on consent. Use when asked to review or merge Renovate PRs across any repo, fix a stalled Renovate or image-publish flow, or deploy merged updates to srv0, vps0, pc, bigpc, or rpi.
---

# Renovate PR Ops

Scope: **every Renovate PR** in `INFRA_REPO` and `APP_REPOS`. App PRs are normally
auto-merged by Renovate after their required `test` check. This skill covers the
exceptions, the app → image publish → Infra refresh ordering, and the Infra PRs
that are the human gate.

## Automation model

- The scheduled `renovate-daily` CronJob is a **pure Renovate run** every six hours.
  It does not merge, wait, or notify.
- App repos extend the shared preset (`github>ImranR98/Infra//renovate-preset`).
  Renovate auto-merges non-major updates (patch/minor/digest/pin/lockfile
  maintenance) itself after the `test` check passes. Majors wait on the
  Dependency Dashboard until approved.
- Infra Renovate PRs are **never auto-merged**. This skill researches, validates,
  and presents them; the user approves the merge.
- The suspended `renovate-infra` CronJob is the on-demand Infra-only template.
  The skill creates a Job from it after app images publish so the new digest PR
  appears immediately instead of waiting for the next scheduled run.
- App repos are remote objects. The only local checkout this skill assumes is the
  Infra repo it runs in.

## Hard rules

- **Never assume an app repo checkout exists.** Use the GitHub API for app PR
  data, checks, and merges. If a local clone is genuinely needed for research,
  clone into `tmp="$(mktemp -d)"`, use it only for that task, and remove it.
- **App PR merge:** only when the `test` check is `success`, the PR is mergeable,
  and research is clean. Merge via the GitHub API with `merge_method: squash`
  (or `gh pr merge --squash` if `gh` is available). Never merge an app PR by
  checking out and pushing an app branch.
- **Wait for the publish job.** A green `test` check only built a local image;
  the default-branch `publish` job pushes `:sha-<commit>`, verifies it, and
  promotes `:latest`. Never refresh Infra after a failed or missing publish.
- **Infra PRs are the human gate.** Present findings and wait for explicit
  approval before merging (unless the user pre-authorized the named batch).
- **Deploy on consent.** One consolidated ask per batch: targets in order, exact
  commands, verification plan, and what stays held.
- Never bypass a failing check, required check, or branch protection.
- Never print, commit, or inspect secret values. Do not paste full logs; extract
  error/phase lines.
- Never commit the user's in-progress Infra work; stash it for local merges and
  restore it afterwards.
- Deploy only where this checkout has access (srv0 locally, vps0 over SSH). For
  pc/bigpc/rpi, print the commands for the user to run instead.

## Autonomy contract

| Work | App non-major | App major / Tier C | Infra PR | Deploy |
|---|---|---|---|---|
| Research | quick skim | required, with evidence | required | required |
| Merge | autonomous (Renovate usually already did) | user consent | user approval | — |
| Deploy | — | — | — | user consent |

- Renovate's own auto-merge handles routine app PRs; this skill merges only the
  exceptions (blocked PRs, approved majors, repos where Renovate could not merge).
- App majors, 0.x minors with breaking signals, and DB migrations need consent.
- Infra PRs are presented as a batch; the user approves.
- An explicit pre-authorization ("merge and deploy whatever is safe") overrides
  these gates for the named items. When unsure, escalate one tier.

Tier assignment for Infra components and app changes is documented in
[references/risk-assessment.md](references/risk-assessment.md).

## Phase 1 — Preflight

- `git status --short`; stash Infra WIP with `git stash push -m "renovate-pr-ops"`
  and restore with `git stash pop` after local Infra merges.
- `hostname` (expect srv0) and `kubectl get nodes` — the admin kubeconfig is
  root-only, so the user must have an unlock session running.
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
default-branch CI runs from the last 48h. Use it to identify:
- app PRs that are green and not yet merged,
- app PRs needing consent (majors/Tier C),
- recent app merges whose images may still be publishing,
- open Infra PRs,
- broken default-branch CI.

If the runner failed, use
[references/daily-run-troubleshooting.md](references/daily-run-troubleshooting.md)
before touching PRs. If an app publish is in flight, wait for it in Phase 4.

## Phase 3 — Triage and research

Classify each open PR by repo and risk:

- **App PRs:** green/ready, major/Tier C needing consent, or red/held. Check the
  app changelog/releases for breaking changes, config/env renames, and DB
  migrations. Use the GitHub API or a temporary clone for code inspection.
- **Infra PRs:** image digest pins (rollout), Helm chart/app versions, k3s Plan
  bumps. Use the risk reference.
- Record the app → image mapping and the order in which app PRs will merge.

Do not use local app paths. `list-prs.sh` already provides the PR repo, number,
head SHA, mergeable state, and check results.

## Phase 4 — App merges and image publishes

1. **Merge or confirm app PRs.**
   - Renovate may already have auto-merged routine PRs. Use the recent-merge
     section to collect their merge commit SHAs.
   - For each remaining green app PR that is approved (non-majors are
     autonomous; majors/Tier C after consent), verify `test` is `success` and
     the PR is mergeable, then merge with a squash:
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
   - Record each merge commit SHA (the PR's `merge_commit_sha`).
2. **Wait for the image publishes.**
   ```bash
   bash .agents/skills/renovate-pr-ops/scripts/wait-for-publish.sh \
     --repo <owner/repo> --sha <merge-sha>
   ```
   - `PUBLISHED`: the app image was built, verified, and promoted.
   - `SKIPPED`/`NO_RUN`: the merge only touched ignored paths (docs,
     `.github/**`, `renovate.json`) or the workflow did not run; no image
     changed, so no Infra refresh is needed for that app.
   - `FAILED`/`TIMEOUT`: report the failing run and continue with other apps.
     Do not claim the new image is pinned; the Infra digest will still point at
     the last successful `:latest`.
3. **Batch.** Merge all approved app PRs first, then wait for all publishes.
   This produces one Infra refresh instead of one per app. If the user insists
   on strict per-PR ordering, repeat the app → publish → refresh sequence one
   PR at a time; it is slower and produces more Renovate runs.

## Phase 5 — Refresh Infra

Only when at least one app image actually published (or a recent app publish is
not yet reflected in an Infra PR):

```bash
bash .agents/skills/renovate-pr-ops/scripts/refresh-infra.sh
```

The helper waits for any active Renovate Job, creates a Job from the suspended
`renovate-infra` CronJob, waits for completion, and polls for the new/updated
Infra Renovate PR. It prints `DIGEST #...` for an `infra-digest-pin` PR and
`INFRA #...` for any other fresh Infra PR. `NO_NEW_PR` means Renovate completed
without changing the digest set (for example, the publish failed or the digest
was already pinned).

Do not run this while an app publish or another Renovate Job is in flight. If
the helper reports `BUSY`, wait for the active Job and retry.

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
5. Restore the Infra stash once the local merges are done.

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
the image workflow publish on master, then a later Renovate Infra pass opens the
digest PR. Merge that digest PR and deploy. There is no same-day derived-only
pass in the runner anymore.

## Phase 8 — Verify and report

Run the verification checklist and dead-pod cleanup from the deploy reference.
Never claim success from `helm upgrade` output alone — verify the running state.

Report format:

- **Daily run** — CronJob verdict (OK/recovered/failed/stale), failed run/retry,
  and what was fixed.
- **App merged** — repo, PR number, title, and whether Renovate auto-merged it
  or the skill merged it.
- **Published** — app, merge SHA, publish run result; note skipped/failed
  publishes.
- **Infra refresh** — Infra Job result and the new/updated Infra PR.
- **Infra merged** — PR number, title, targets, and user approval.
- **Deployed** — target, what changed, verification result.
- **Held** — PR plus reason and evidence; what the next run should re-check.
- **Pending commands** — for machines this agent cannot reach.
- **Alerts** — failed default-branch CI runs, failed/pending PR checks, and open
  Dependabot/OSV alerts; say "none" if clean.

## Helpers

- `scripts/daily-health.sh` — pure Renovate CronJob health.
- `scripts/list-prs.sh [--recent HOURS]` — all-repo PR inventory, recent merges,
  failed default-branch CI.
- `scripts/wait-for-publish.sh --repo R --sha S` — wait for the app `publish`
  job on a merge commit.
- `scripts/refresh-infra.sh [--dry-run]` — on-demand Infra-only Renovate Job and
  digest-PR wait.

All helpers use the GitHub API for app data and never assume an app checkout.
