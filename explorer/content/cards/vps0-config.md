---
id: vps0/config/compose
title: vps0 compose.env
summary: "The public shape of vps0 configuration, including domains, Authelia secrets, app secrets, and optional profiles."
tags: [config]
---
vps0 uses native Compose env interpolation. Values with `$` must be single-quoted; multiline values use `\n` escapes. Authelia users and access rules are real files under `config/vps0/authelia/`, not env keys.

The tours show key names and consumers, never values. If a key is still a placeholder in the template, it is marked required.
