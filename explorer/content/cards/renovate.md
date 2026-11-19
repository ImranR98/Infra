---
id: srv0/base/renovate
title: Renovate
summary: "A pure six-hourly CronJob. App PRs auto-merge after test; Infra PRs stay manual."
facts:
  - label: Schedule
    value: 0 */6 * * * (America/Toronto)
    mono: true
  - label: Merge policy
    value: app non-major auto; Infra manual
---
The scheduled CronJob runs Renovate every six hours and does one thing: a Renovate pass. Renovate opens/updates PRs and auto-merges non-major app updates after `test`; a thin wrapper also posts a best-effort ntfy summary. Infra PRs are never auto-merged.

App repos extend `renovate-preset.json`; majors wait on the Dependency Dashboard. There is no release-age hold: an update opens on the first run after its registry or chart publishes it. Infra PRs are the manual rollout gate handled by the `renovate-pr-ops` skill.

First-party app images (`ghcr.io/imranr98/**`, `:latest@sha`) and genuinely channel-only images (LinuxServer `latest`, ComfyUI `xpu-master`, llama.cpp channel tags, temporary Bitnami DB/kubectl pins) publish no immutable version tag, so they are digest-pinned and reviewed at the manual rollout gate. Everything else uses an immutable version tag. `scripts/check-images.sh` enforces tags and digests; pc and bigpc images are Renovate-managed too.
