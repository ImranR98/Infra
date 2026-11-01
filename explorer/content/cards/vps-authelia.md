---
id: vps0/service/authelia
title: Authelia (vps0)
summary: "The edge SSO instance. Its base config is committed; deployment-specific access rules are rendered from config at deploy time."
tags: [auth]
---
This Authelia is the forward-auth provider for the cloud zone and a few base-domain apps. The structural configuration lives in `targets/vps0/compose/files/authelia/configuration.base.yml`; the deployment-specific access rules live in `config/vps0/authelia/access_control.yml`.

`scripts/render-vps0-authelia.sh` injects the rules and writes the live file; `compose.sh vps0 up` runs it automatically. Redis is the session store. The admin catch-all is the only `two_factor` rule; family/guest apps intentionally use `one_factor`.
