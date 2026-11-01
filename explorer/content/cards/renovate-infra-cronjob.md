---
id: srv0/base/renovate/cronjob/renovate-infra
title: renovate-infra CronJob
subtitle: suspended · on-demand template
summary: "The Infra-only template the renovate-pr-ops skill creates a Job from after an app image publishes."
---
The CronJob is suspended, so its placeholder schedule never fires. The skill creates a Job from this template after an app PR merges and its image `publish` job finishes, so the new digest PR appears immediately instead of waiting for the next six-hourly run. Job history is retained for debugging.
