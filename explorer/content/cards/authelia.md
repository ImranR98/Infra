---
id: srv0/base/authelia
title: Authelia
summary: "The SSO gate. Structural bypasses live in the chart; deployment-specific access rules live in config."
tags: [auth, security]
---
Authelia is the forward-auth provider for the routes that need SSO. It also issues OIDC clients for Immich, Open WebUI, Headlamp, Linkwarden, and FileBrowser.

The access-control split is intentional: the chart owns the ACME/app bypasses and the final admin catch-all; `AUTHELIA_ACCESS_CONTROL_RULES` in `config/srv0/values.yaml` owns the deployment-specific domains, groups, and one-factor/two-factor choices. First match wins. Don't put personal group names in the chart.

The six apps with their own authentication deliberately have no Authelia forward-auth filter. `BOOTSTRAP_PRIVATE_APPS` is the first-boot containment switch, not a permanent gate.
