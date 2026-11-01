---
id: decision/auth/app-own-login
title: Six apps keep their own login
appliesTo:
  - srv0/apps/media/immich
  - srv0/apps/media/jellyfin
  - srv0/apps/media/navidrome
  - srv0/apps/media/opodsync
  - srv0/apps/home/homeassistant
  - srv0/apps/productivity/linkwarden
---
Home Assistant, Immich, Jellyfin, Linkwarden, Navidrome, and Opodsync have no Authelia forward-auth filter. They have their own authentication and, in some cases, native apps that do not handle a forward-auth redirect well.

`BOOTSTRAP_PRIVATE_APPS=true` is the first-boot containment switch: it removes the public `websecure-proxy` parentRef from those routes until Authelia is Ready. It is not a permanent security boundary.
