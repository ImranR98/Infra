# Runner and publish troubleshooting

The scheduled runner is a pure Renovate CronJob. App PRs are merged by Renovate
(or this skill), and app images are built by each repo's own CI. Diagnose the
runner, the app publish, and the Infra pin/refresh separately.

## 1. Gather evidence

```bash
bash .agents/skills/renovate-pr-ops/scripts/daily-health.sh; echo "exit=$?"
bash .agents/skills/renovate-pr-ops/scripts/list-prs.sh --recent 24
```

`daily-health.sh` reports the `renovate-daily` CronJob's last schedule/success,
the newest Job and pod attempts, and Renovate's `ERROR:`/`WARN:` lines. A pure
Renovate run has no `==> [n/9]` markers; `phases: n/a` is expected.

`list-prs.sh` reports open Renovate PRs across all repos with their checks,
recent merges, and failed default-branch CI runs.

If `daily-health.sh` exits 2, the admin kubeconfig is root-only; start
`bash scripts/kubeconfig-unlock.sh`. Manual evidence:

```bash
kubectl -n base get cronjob renovate-daily
kubectl -n base get jobs --sort-by=.metadata.creationTimestamp
kubectl -n base get pods -l app=renovate -o wide
kubectl -n base logs job/renovate-daily-<timestamp> --tail=2000 |
  grep -nE '^ ?(ERROR|WARN):'
```

Extract error lines; do not paste entire Renovate logs.

## 2. Runner failures

| Symptom | Check | Action |
|---|---|---|
| `401`/`403`/`Bad credentials` | Renovate log | `RENOVATE_TOKEN` expired/under-scoped. Ask before rotating; never print it |
| `429`/rate limit | Renovate log, GitHub status | wait for the next 6-hour run; check the token's rate limit |
| `config-validation` / `Cannot find preset` | Renovate log, app `renovate.json` | fix the app config or the shared `renovate-preset.json`; validate it |
| `Repository has invalid config` | Renovate log | fix that app's config; the other repos continue |
| `OOMKilled`, exit 137 | pod termination | capture evidence; propose a memory limit bump (consent) |
| `ImagePullBackOff` | pod events | pinned Renovate image unavailable; check registry/network |
| Job active > 2h | Job/pod age | `activeDeadlineSeconds: 7200` should end it; inspect before deleting anything |
| Job failed with logs gone | `failedJobsHistoryLimit: 3` | use the Grafana alert/Loki; rerun a one-off Job after the cause is fixed |

A failed pod followed by a successful retry is `RECOVERED`. The pure runner does
not send per-attempt notifications; the Grafana `renovate-daily-job-failed`
alert only fires for a finally-failed Job.

## 3. App PR and publish failures

- **Open but not merged:** every open app Renovate PR is a work item. If the
  repo's required check is green (usually `test=success`; `validate=success` on
  config-only repos), `stability=success`/`missing`, and the PR is mergeable,
  the skill may merge it now; do not wait for the next six-hourly Renovate run.
- **`stability=pending`:** `renovate/stability-days` is holding the update for
  the minimum release age. With `internalChecksFilter: strict` new branches
  should not appear pending; treat an old one as a leftover and report it. Do
  not merge early.
- **Red app PR:** read the failed `test` check and the app CI job. Fix the app
  repo; Renovate will refresh/rebase the PR and retry. Do not merge a red PR.
- **Renovate cannot auto-merge:** confirm the required check is `success`
  (usually `test`; `validate` on config-only repos), the stability status is not
  pending, and the PR is mergeable. A 405/409 is a conflict/race; leave it open
  and report it. The skill can merge the PR via the API once it is ready.
- **No publish job:** the repo is config-only or has no publishable image.
  Merge it if its own checks pass; nothing to pin.
- **Publish failed:** the default-branch `publish` job is red. A failed publish
  does not move `:latest`, so the Infra pin still points at the last successful
  image. Do not claim the new version is pinned or deployed; fix the app CI.
- **Publish skipped/no run:** the merge likely only touched `paths-ignore`
  files (docs, `.github/**`, `renovate.json`). No image changed; no Infra pin.
- **Infra pin not appearing:** the digest PR is opened by the next scheduled
  Renovate run (every six hours). If it is still missing after a successful
  publish, run `bash scripts/renovate.sh infra` and re-run `list-prs.sh`. Never
  edit the digest by hand.

## 4. Infra refresh failures

The scheduled run is the primary path; `scripts/renovate.sh infra` is the
on-demand fallback (same pinned Renovate version, local token/cache).

| Result | Meaning | Action |
|---|---|---|
| Job failed | Renovate error | read the Job log, fix the cause, rerun |
| `NO_NEW_PR` | no digest changed | check the publish result; the digest may already be pinned |
| timeout | runner or API slow | inspect the Job; retry after it finishes |

Do not run an Infra refresh while an app publish or another Renovate Job is in
flight; the digest would be stale. Infra changes are PR-only; never commit a
digest by hand.

## 5. Infra PR failures

- Red `validate`: fetch the PR ref into the local Infra repo and reproduce with
  `bash scripts/validate.sh <target>`.
- Missing required check: the `Validate` workflow did not run; check the Actions
  workflow, not the PR.
- Conflicted PR: resolve or leave it for Renovate to rebase; never force-merge.
- A `validate` failure caused by an Infra test fixture is a repo fix, not an
  app dependency problem.

## 6. Repair policy

Autonomous:

- run the health/inventory helpers, read logs/checks;
- merge app PRs via the API when `test` is green, `stability` is not pending,
  and the PR is approved (routine app PRs are usually already auto-merged by
  Renovate);
- run `scripts/renovate.sh infra` and re-run `list-prs.sh` when a published
  image has no Infra digest PR yet;
- validate the Infra PR for the touched targets;
- report failures that need app-code, secret, workflow, or chart changes.

Ask first:

- merge an Infra PR or deploy;
- rotate/change the token, Docker Hub credentials, or any secret;
- edit the shared preset, app CI, the runner chart, or the skill;
- suspend/delete Jobs, raise limits, force-push branches, or change branch
  protection.

Never:

- merge a red, stability-held, or unapproved Infra PR;
- edit an Infra digest by hand or claim a version is pinned after a failed
  publish;
- bypass a check, required check, stability hold, or branch protection;
- assume an app checkout exists;
- print secrets or full logs.

## 7. Rerun recipes

On-demand Infra-only run (same pinned Renovate version as the scheduled runner;
uses config/VARS.env for the token):

```bash
bash scripts/renovate.sh infra
```

Full Renovate rerun (all repos), only after the cause is fixed:

```bash
job="renovate-daily-manual-$(date -u +%Y%m%d%H%M%S)"
kubectl -n base create job --from=cronjob/renovate-daily "$job"
kubectl -n base logs -f "job/$job"
```

Do not run `scripts/renovate-daily.sh` on the host; it has been removed. The
runner is the CronJob image with env/Secret inputs only.

## 8. Verify

- `daily-health.sh` exits 0 with `VERDICT: OK` (or `RECOVERED` with errors
  explained).
- Each app merge that changed an image has an Infra digest PR within one
  scheduled cycle (or after `scripts/renovate.sh infra`); skipped/no-publish
  merges are explained.
- The Infra PR passes local `validate` and is approved before merge/commit.
- The deploy verification checklist is clean.
- The Grafana `renovate-daily-job-failed`/`cronjob-stale-renovate` alerts clear
  after the next successful scheduled run; they are not proof on their own.
