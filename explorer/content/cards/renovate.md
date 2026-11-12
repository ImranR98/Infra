---
id: srv0/base/renovate
title: Renovate
summary: "A pure six-hourly CronJob. App PRs auto-merge after test and the 3-day age gate; Infra PRs stay manual."
facts:
  - label: Schedule
    value: 0 */6 * * * (America/Toronto)
    mono: true
  - label: Merge policy
    value: app non-major auto; Infra manual
---
The scheduled CronJob runs Renovate every six hours and does one thing: a Renovate pass. Renovate opens/updates PRs and auto-merges non-major app updates after `test`; a thin wrapper also posts a best-effort ntfy summary. Infra PRs are never auto-merged.

App repos extend `renovate-preset.json`; majors wait on the Dependency Dashboard. `minimumReleaseAge` is **3 days for everything**, with `internalChecksFilter: strict` and `minimumReleaseAgeBehaviour: timestamp-required`; an update without a release timestamp is not eligible. Infra PRs are the manual rollout gate handled by the `renovate-pr-ops` skill.

First-party app images (`ghcr.io/imranr98/**`, `:latest@sha`) are the one deliberate age exception: the tag is rebuilt on every app merge, so it is allowlisted and the next Renovate run opens the digest PR immediately. The same allowlist covers genuinely channel-only images (LinuxServer `latest`, ComfyUI `xpu-master`, llama.cpp channel tags, temporary Bitnami DB/kubectl pins). Everything else uses an immutable version tag and waits the 3 days. `scripts/check-images.sh` enforces tags and digests; pc and bigpc images are Renovate-managed too. If a non-allowlisted image stays pending for more than 3 days, its tag is being rebuilt faster than the gate — pin an immutable tag or add a justified allowlist entry.
