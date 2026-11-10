---
id: concept/renovate-pr-ops
title: renovate-pr-ops skill
subtitle: cross-repo Renovate gate
parent: srv0/ops/renovate
summary: "The cross-repo workflow: app-PR exceptions, the Infra PR approval batch, and deploys."
---
This is a skill, not a cluster component. It inventories all Renovate PRs across the Infra repo and every app repo, merges ready app PRs that Renovate left open (and approved majors), and researches/validates the Infra PRs for approval.

Infra digest pins are opened by Renovate on the next scheduled run after an app image publishes; the skill never edits a digest by hand. It can run `scripts/renovate.sh infra` to refresh on demand. No app checkout is assumed: the skill uses the GitHub API or a temporary clone.
