---
id: concept/renovate-pr-ops
title: renovate-pr-ops skill
subtitle: cross-repo Renovate gate
parent: srv0/ops/renovate
summary: "The cross-repo workflow: app-PR exceptions, the Infra PR approval batch, and deploys."
---
This is a skill, not a cluster component. It inventories all Renovate PRs across the Infra repo and every app repo, merges ready app PRs that Renovate left open (and approved majors), and researches/validates the Infra PRs for approval.

First-party app image digest pins (`ghcr.io/imranr98/**`) are allowlisted and opened on the next scheduled run; third-party images wait for the 3-day age gate. The skill never edits a digest by hand. It can run `scripts/renovate.sh infra` to refresh on demand, but that does not bypass the age gate. No app checkout is assumed: the skill uses the GitHub API or a temporary clone.
