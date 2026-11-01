---
id: srv0/base/renovate/cronjob/renovate-daily
title: renovate-daily CronJob
subtitle: six-hourly · pure PR pass
summary: "The scheduled Renovate runner. Renovate opens and refreshes PRs and auto-merges non-major app PRs after test; Infra PRs stay manual."
---
The Job runs `renovate` against the Infra repo plus the app/ops repos every six hours. Renovate opens/refreshes PRs and auto-merges non-major app updates after `test`; there is no custom merge/wait/notify wrapper. Infra PRs remain manual. It mounts no repo or scripts; the image, token, repo lists, host rules, and git author come from the chart and `renovate-secrets`.
