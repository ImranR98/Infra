---
name: renovate-pr-ops
description: Cross-repo Renovate operations for the Infra homelab. Inventory and merge app-repo Renovate PRs (including open-but-unmerged ones), work the Infra PRs (the manual gate), and deploy on consent. Use when asked to review or merge Renovate PRs across any repo, fix a stalled Renovate or image-publish flow, or deploy merged updates to srv0, vps0, pc, bigpc, or rpi.
---

# Renovate PR Ops

Scope: **every Renovate PR** in `INFRA_REPO` and `APP_REPOS` — not only the Infra
repo. App PRs that Renovate has not merged are work items too (missed auto-merge,
blocked, failed, or a major awaiting approval). Infra PRs are the human gate.

## Automation model

- The scheduled `renovate-daily` CronJob is a **pure Renovate run** every six
  hours over Infra plus every app repo. It does not merge, wait, or notify
  beyond its best-effort ntfy summary.
- App repos extend the shared preset (`github>ImranR98/Infra//renovate-preset`).
  Renovate auto-merges non-major updates (patch/minor/digest/pin/lockfile
  maintenance) after the required `test` check. `internalChecksFilter: strict`
  means a PR only appears once its minimum-release-age check passes; majors wait
  on the Dependency Dashboard until approved.
- Merging an app PR triggers the app's `ci.yml`: `test`, then `publish` to GHCR
  (`:sha-<commit>` verified, `:latest` promoted). Workflow-only merges are
  path-ignored and publish nothing.
- The **next scheduled Renovate run** sees the promoted `:latest` digest and
  opens/refreshes the grouped Infra `docker-digests` PR (plus separate PRs for
  chart, k3s Plan, and other versioned dependencies). Infra is never
  auto-merged; this skill researches, validates, and presents those PRs.
- If a fresh Infra PR is needed without waiting for the schedule, run
  `bash scripts/renovate.sh infra` locally (same pinned Renovate version as the
  CronJob), then re-run `list-prs.sh`.
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
- **Never pin an app image by hand.** The Infra digest PR is Renovate's job; it
  only sees a new digest after the app's `publish` job has promoted `:latest`.
  If the PR is absent, the publish has not finished (or failed); report it and
  let the next run pick it up.
- **Infra changes are the human gate.** Show the PR diff and `validate` result,
  wait for explicit approval, then merge and push (unless the user
  pre-authorized the named batch). Never auto-merge Infra.
- **Deploy on consent.** One consolidated ask per batch: targets in order, exact
  commands, verification plan, and what stays held.
- Never bypass a failing check, required check, or branch protection.
- Never print, commit, or inspect secret values. Do not paste full logs; extract
  error/phase lines.
- Never commit the user's in-progress Infra work; stash it for local updates and
  restore it afterwards.
- Deploy only where this checkout has access (srv0 locally, vps0 over SSH). For
  pc/bigpc/rpi, print the commands for the user to run instead.

## Autonomy contract

| Work | App non-major | App major / Tier C | Infra PR | Deploy |
|---|---|---|---|---|
| Research | quick skim | required, with evidence | required | required |
| Merge | autonomous when checks are green | user consent | user approval | — |
| Deploy | — | — | — | user consent |

- Renovate's own auto-merge handles routine app PRs on its next run; this skill
  only finishes the ones it left behind and merges the exceptions (blocked PRs,
  approved majors, repos where Renovate could not merge).
- App majors, 0.x minors with breaking signals, and DB migrations need consent.
- Infra PRs are presented as a batch; the user approves before the merge/push.
- An explicit pre-authorization ("merge and deploy whatever is safe") overrides
  these gates for the named items. When unsure, escalate one tier.

Tier assignment for Infra components and app changes is documented in
[references/risk-assessment.md](references/risk-assessment.md).

## Phase 1 — Preflight

- `git status --short`; stash Infra WIP with `git stash push -m "renovate-pr-ops"`
  and restore with `git stash pop` after local Infra updates.
- `hostname` (expect srv0) and `kubectl get nodes` — the admin kubeconfig is
  root-only, so the user must have an unlock session running. Inventory and
  merges work without cluster access; only the runner health check and deploys
  need the unlock.
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

`list-prs.sh` lists every open Renovate PR across Infra and all app repos with
its checks, plus recent merged Renovate PRs (default 24h) and failed
default-branch CI runs from the last 48h. Each PR line shows the check names
(usually `test`, plus `status`/`stability`/`major`). Use it to identify:
- app PRs that are ready to merge now (required check `success`, usually
  `test=success`; `validate=success` on config-only repos; `stability=success`),
- app PRs needing consent (`major=yes`),
- app PRs that are red, conflicted, or have no `test` run,
- app PRs unexpectedly stuck at `stability=pending` (strict filtering should
  prevent new ones; treat an old branch as a leftover and report it),
- recent app merges whose Infra pin has not appeared yet,
- open Infra PRs,
- broken default-branch CI.

If a known app merge is older than the default recency window, widen it with
`--recent 48` (or more). If the runner failed, use
[references/daily-run-troubleshooting.md](references/daily-run-troubleshooting.md)
before touching PRs.

## Phase 3 — Triage and research

Classify each open PR by repo and risk:

- **App PRs:** ready, major/Tier C needing consent, or red/held. Check the app
  changelog/releases for breaking changes, config/env renames, and DB
  migrations. Use the GitHub API or a temporary clone for code inspection.
- **Infra PRs:** grouped image digests (rollout), Helm chart/app versions, k3s
  Plan bumps, nfs-server source deps. Use the risk reference.
- Record the app → image mapping for any recently merged app whose Infra pin is
  still pending.

Do not use local app paths. `list-prs.sh` already provides the PR repo, number,
head SHA, mergeable state, check/status/stability results, and recent merges.

## Phase 4 — App merge exceptions

Renovate normally merges its own non-major PRs on the next six-hourly run. This
phase exists only for the leftovers:

1. **Merge a ready non-major PR** that Renovate has not merged (for example the
   next run is hours away) when the required check is `success`,
   `stability=success`/`missing`, the PR is mergeable, and research is clean:
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
2. **Merge an approved major/Tier C** only after explicit consent and the same
   green checks.
3. **Do not merge anything `stability=pending`.** Report it; Renovate owns it.
4. **Do not wait for publish jobs.** The scheduled Infra run picks up the new
   digest. Record the merge commit SHA and note the app as "Infra pin pending";
   the next skill run (or `renovate.sh infra`) will surface the PR.
5. Config-only repos (`dscpln-config`, `*-config`) have no image; nothing to pin.

## Phase 5 — Infra PRs (human gate)

1. Triage all open Infra Renovate PRs, not only digest pins. Research charts,
   app versions, k3s Plans, and digest batches with the risk reference.
2. If an app image is known to have published but no digest PR exists yet, run
   `bash scripts/renovate.sh infra` (needs the token; no cluster access) and
   re-run `list-prs.sh`. Do not edit digests by hand.
3. For each approved batch, run `bash scripts/validate.sh <target>` on the PR
   ref and present the risk, evidence, and recommendation.
4. Wait for explicit approval, then merge locally and push:
   ```bash
   git fetch origin pull/<n>/head:renovate/pr-<n>
   git checkout renovate/pr-<n>
   bash scripts/validate.sh <target>        # every target the PR touches
   git checkout master
   git merge --no-ff -m "Merge pull request #<n> from <owner>/<branch>" \
     -m "<PR title>" renovate/pr-<n>
   git push origin master
   ```
5. `infra-digest-pin` marks image pins that need a rollout. Merging is inert
   until the deploy.
6. Restore the Infra stash once the local changes are done.

## Phase 6 — Deploy (on consent)

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

This is a normal two-step Infra flow: merge the Dockerfile/base bump, let the
image workflow publish on master, then the next scheduled Renovate run opens the
nfs-server digest PR. Merge that PR, then deploy.

## Phase 7 — Verify and report

Run the verification checklist and dead-pod cleanup from the deploy reference.
Never claim success from `helm upgrade` output alone — verify the running state.

Report format:

- **Daily run** — CronJob verdict (OK/recovered/failed/stale), failed run/retry,
  and what was fixed.
- **App PRs** — merged vs held, repo/number/title, and whether Renovate
  auto-merged or the skill merged it. Call out majors awaiting approval and any
  unexpected `stability=pending`.
- **Published** — app merges that changed an image; note when the Infra pin is
  still pending (with the merge SHA).
- **Infra merged** — PR number, title, targets, old → new digest(s), and user
  approval.
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

Both helpers read the repo list from `config/srv0/values.yaml` via
`scripts/repos.sh` (the same source the CronJob uses) and use the GitHub API;
they never assume an app checkout.
