---
id: srv0/config/values
title: srv0 values.yaml
summary: "The public shape of srv0 configuration. Real values are gitignored and never read by the tours."
tags: [config]
---
This is the committed template, not the secret file. It documents every key, its generation command, and the context that makes it non-obvious.

The important split: Helm values feed both charts; the Compose sidecar has its own `compose.env` and WireGuard files. Machine facts (`MY_UID`, `DOCKER_GID`, `MY_USERNAME`) are generated into `targets/<t>/compose/.env` and never live in config envs.
