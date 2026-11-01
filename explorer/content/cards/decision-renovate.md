---
id: decision/updates/merge-is-not-deploy
title: Merging is not deploying
appliesTo:
  - srv0/base/renovate
  - srv0/base/renovate/cronjob/renovate-daily
  - srv0/base/renovate/cronjob/renovate-infra
---
The scheduled CronJob runs Renovate only. Renovate opens/refreshes PRs and auto-merges non-major app updates after `test`; Infra Renovate PRs are never auto-merged. The `renovate-pr-ops` skill waits for app image publishes, triggers the on-demand `renovate-infra` Job, and presents the Infra batch for approval.

An Infra merge is still only desired state: `scripts/deploy.sh <target>` performs the rollout. Digest pins carry `infra-digest-pin` so the skill can group them with the deploy.
