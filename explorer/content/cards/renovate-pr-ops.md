---
id: concept/renovate-pr-ops
title: renovate-pr-ops skill
subtitle: cross-repo Renovate gate
parent: srv0/ops/renovate
summary: "The cross-repo workflow: open app PRs, publish wait, direct Infra digest pin, and the manual Infra approval batch."
---
This is a skill, not a cluster component. It inventories all Renovate PRs across Infra and the app repos, merges ready app PRs (including ones Renovate left open), waits for the app image `publish` job, and pins the promoted digest directly in the Infra repo with `pin-app-image.sh`. The Infra change is presented for approval before commit/push.

The on-demand `renovate-infra` Job remains available for non-app or missed updates. No app checkout is assumed: the skill uses the GitHub and GHCR APIs or a temporary clone.
