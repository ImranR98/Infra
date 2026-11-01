---
id: srv0/base/system-upgrade
title: K3s upgrades
summary: "The vendored system-upgrade-controller and Plans that own the K3s version."
tags: [cluster, updates]
---
The controller manifests are vendored in `system-upgrade-controller.yaml`; the server and agent Plans pin K3s versions and are Renovate-managed through the plan-version regex.

The installer scripts only run when K3s is missing, so they never fight the controller for version ownership. Apply `srv0-base`, then watch `kubectl -n system-upgrade get plans,jobs`.
