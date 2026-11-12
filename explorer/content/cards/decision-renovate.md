---
id: decision/updates/merge-is-not-deploy
title: Merging is not deploying
appliesTo:
  - srv0/base/renovate
  - srv0/base/renovate/cronjob/renovate-daily
---
The scheduled CronJob runs Renovate only. Renovate opens/refreshes PRs and auto-merges non-major app updates after `test`; Infra Renovate PRs are never auto-merged. The `renovate-pr-ops` skill merges app-PR exceptions, presents the Infra batch for approval, and deploys on consent.

An Infra merge is still only desired state: the rollout is `scripts/validate.sh <target>` followed by the `helm upgrade` or `sudo docker compose up` commands. Renovate digest PRs carry `infra-digest-pin` so the skill can group them with the deploy.
