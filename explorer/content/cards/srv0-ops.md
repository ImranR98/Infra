---
id: srv0/ops
title: Operations
summary: "The recurring work: updates, backups, CI, remote access, and the deploy/validate tooling."
tags: [updates, storage, auth]
---
Operations are first-class parts of the architecture, not an appendix. The map connects them to the things they touch:

- **Renovate** is split: a pure six-hourly CronJob runs Renovate, which opens/updates PRs and auto-merges non-major app PRs after test; all Infra PRs remain the manual gate handled by the `renovate-pr-ops` skill. A deploy is still required.
- **State backups** run through the D$CPLN Task Runner into one restic repository; restore is a standalone script.
- **CI** validates the repo and publishes the NFS server image.
- **Remote access** covers the public-exposure client, AmneziaWG, and initramfs LUKS unlock.
- **Deploy tooling** is the shared validate → compose/Helm path.

Click a script to see its phases and the config keys it reads. This is where the details live that a flat reference page made hard to find.
