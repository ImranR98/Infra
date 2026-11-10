---
id: srv0/base/renovate/cronjob/renovate-daily
title: renovate-daily CronJob
subtitle: six-hourly · pure PR pass
summary: "The scheduled Renovate runner. Renovate opens and refreshes PRs and auto-merges non-major app PRs after test; Infra PRs stay manual."
---
The Job runs `renovate` against the Infra repo plus the app/ops repos every six hours. Renovate opens/refreshes PRs and auto-merges non-major app updates after `test`; a thin wrapper runs the pass and posts a best-effort ntfy summary of new deps PRs. Infra PRs remain manual. The runner mounts the wrapper and notifier ConfigMap (not the Infra checkout); the image, token, repo lists, host rules, and git author come from the chart and `renovate-secrets`.
