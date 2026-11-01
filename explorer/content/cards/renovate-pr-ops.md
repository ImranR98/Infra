---
id: concept/renovate-pr-ops
title: renovate-pr-ops skill
subtitle: cross-repo Renovate gate
parent: srv0/ops/renovate
summary: "The cross-repo workflow: app exceptions, publish wait, on-demand Infra refresh, and the manual Infra approval batch."
---
This is a skill, not a cluster component. It triages app-repo Renovate exceptions, merges approved majors, waits for the app image `publish` job, creates a Job from the suspended `renovate-infra` CronJob, and presents the resulting Infra PRs for approval.

No app checkout is assumed: it uses the GitHub API or a temporary clone.
