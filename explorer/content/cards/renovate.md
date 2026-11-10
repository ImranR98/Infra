---
id: srv0/base/renovate
title: Renovate
summary: "A pure six-hourly CronJob. App PRs auto-merge after test; the next run opens the Infra digest PR, and Infra PRs stay manual."
facts:
  - label: Schedule
    value: 0 */6 * * * (America/Toronto)
    mono: true
  - label: Merge policy
    value: app non-major auto; Infra manual
---
The scheduled CronJob runs Renovate every six hours and does one thing: a Renovate pass. Renovate opens/updates PRs and auto-merges non-major app updates after `test`; a thin wrapper also posts a best-effort ntfy summary. Infra PRs are never auto-merged.

App repos extend `renovate-preset.json`; majors wait on the Dependency Dashboard. `internalChecksFilter: strict` holds an update until it is eligible, and `minimumReleaseAgeBehaviour: timestamp-optional` lets digest updates without a release timestamp through. Infra PRs are the manual rollout gate handled by the `renovate-pr-ops` skill.

After an app PR merges and its image `publish` job promotes `:latest`, the **next scheduled Renovate run** opens the grouped Infra digest PR. There is no manual pin step; if a fresh PR is needed sooner, `scripts/renovate.sh infra` runs the same Renovate version on demand.
