---
id: srv0/apps
title: Apps
summary: "The app catalog, grouped by purpose. Each app owns its route, storage, security posture, and update pin."
tags: [apps]
---
The apps namespace is intentionally not a monolith. Each template file is a per-app record: its resources, route, middleware chain, storage claims, probes, and image pins live together. The tours reflect that: open an app and you see its moving parts, not a generated abstraction.

Use the category groups in the app-catalog tour. The six user-facing apps with their own authentication (Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, Opodsync) have no Authelia forward-auth filter; that is a deliberate security decision, not an omission.
