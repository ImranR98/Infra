---
id: srv0/base/renovate
title: Renovate
summary: "A pure six-hourly CronJob plus a suspended Infra-only template. App PRs auto-merge after test; Infra PRs stay manual."
facts:
  - label: Schedule
    value: 0 */6 * * * (America/Toronto)
    mono: true
  - label: Merge policy
    value: app non-major auto; Infra manual
---
The scheduled CronJob runs Renovate every six hours and does one thing: a Renovate pass. Renovate opens/updates PRs and auto-merges non-major app updates after `test`; there is no custom merge/wait/notify wrapper. Infra PRs are never auto-merged.

App repos extend `renovate-preset.json`; majors wait on the Dependency Dashboard. Infra PRs are never auto-merged — they are the manual rollout gate.

After an app PR merges and its image `publish` job completes, the `renovate-pr-ops` skill creates a Job from the suspended `renovate-infra` CronJob. The new Infra digest PR appears immediately instead of waiting for the next six-hourly run.
