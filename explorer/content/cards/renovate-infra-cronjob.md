---
id: srv0/base/renovate/cronjob/renovate-infra
title: renovate-infra CronJob
subtitle: suspended · on-demand template
summary: "The optional Infra-only template for on-demand refreshes after app image publishes or for non-app updates."
---
The CronJob is suspended, so its placeholder schedule never fires. The `renovate-pr-ops` skill normally pins a published app image digest directly in Infra; it creates a Job from this template only for non-app or missed updates, so a fresh digest PR can appear without waiting for the next six-hourly run. Job history is retained for debugging.
