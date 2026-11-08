---
id: decision/updates/merge-is-not-deploy
title: Merging is not deploying
appliesTo:
  - srv0/base/renovate
  - srv0/base/renovate/cronjob/renovate-daily
  - srv0/base/renovate/cronjob/renovate-infra
---
The scheduled CronJob runs Renovate only. Renovate opens/refreshes PRs and auto-merges non-major app updates after `test`; Infra Renovate PRs are never auto-merged. The `renovate-pr-ops` skill merges ready open app PRs, waits for app image publishes, pins the promoted digests directly in Infra, and presents the Infra batch for approval. The on-demand `renovate-infra` Job is an optional path for non-app or missed updates.

An Infra merge or manual pin is still only desired state: `scripts/deploy.sh <target>` performs the rollout. Renovate digest PRs carry `infra-digest-pin` so the skill can group them with the deploy.
