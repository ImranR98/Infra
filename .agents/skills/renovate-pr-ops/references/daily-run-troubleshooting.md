# Runner and publish troubleshooting

The scheduled runner is a pure Renovate CronJob. App PRs are merged by Renovate
(or this skill), and app images are built by each repo's own CI. Diagnose the
runner, the app publish, and the Infra refresh separately.

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

- **Red app PR:** read the failed `test` check and the app CI job. Fix the app
  repo; Renovate will refresh/rebase the PR and retry. Do not merge a red PR.
- **Renovate cannot auto-merge:** confirm the `test` check is `success` and the
  PR is mergeable. A 405/409 is a conflict/race; leave it open and report it.
  The skill can merge the PR via the API once it is green.
- **Publish failed:** `wait-for-publish.sh` prints `FAILED` with the run URL;
  read the `publish` job. A failed publish does not move `:latest`, so the Infra
  digest PR will still pin the last successful image. Do not claim the new
  version is deployed.
- **Publish skipped/no run:** the merge likely only touched `paths-ignore`
  files (docs, `.github/**`, `renovate.json`). No image changed; skip the Infra
  refresh for that app.
- **Publish timed out:** inspect the run; do not refresh Infra until the publish
  either succeeds or is abandoned. If a later app publish succeeds, a separate
  refresh can proceed.

## 4. Infra refresh failures

`refresh-infra.sh` creates a Job from `cronjob/renovate-infra` and waits for a
fresh Infra PR.

| Result | Meaning | Action |
|---|---|---|
| `BUSY` | another Renovate Job is active | wait for it; retry |
| Job failed | Renovate error | read the Job log, fix the cause, rerun |
| `NO_NEW_PR` | Renovate completed but no digest changed | check the publish result; the digest may already be pinned |
| `DIGEST`/`INFRA` | a fresh PR is ready | triage it in Phase 6 |
| timeout | runner or API slow | inspect the Job; retry after it finishes |

Do not run an Infra refresh while an app publish is in flight; the digest would
be stale.

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
- merge app PRs via the API when `test` is green and the PR is approved (routine
  app PRs are usually already auto-merged by Renovate);
- wait for publishes;
- create the on-demand Infra Job and wait for the PR;
- report failures that need app-code, secret, workflow, or chart changes.

Ask first:

- rotate/change the token, Docker Hub credentials, or any secret;
- edit the shared preset, app CI, the runner chart, or the skill;
- suspend/delete Jobs, raise limits, force-push branches, or change branch
  protection.

Never:

- merge a red or unapproved Infra PR;
- refresh Infra after a failed publish and call the new digest pinned;
- bypass a check or branch protection;
- assume an app checkout exists;
- print secrets or full logs.

## 7. Rerun recipes

On-demand Infra-only run (same image/env as the scheduled runner):

```bash
bash .agents/skills/renovate-pr-ops/scripts/refresh-infra.sh
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
- `wait-for-publish.sh` returns `PUBLISHED` for each app merge that changed an
  image; skipped/no-run is explained.
- `refresh-infra.sh` returns a fresh Infra PR; `NO_NEW_PR` is explained.
- The Infra PR passes local `validate` and is approved before merge.
- The deploy verification checklist is clean.
- The Grafana `renovate-daily-job-failed`/`cronjob-stale-renovate` alerts clear
  after the next successful scheduled run; they are not proof on their own.
