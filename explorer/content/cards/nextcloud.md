---
id: srv0/apps/productivity/nextcloud
title: Nextcloud
summary: "The file sync and share app. Chart-managed, NFS-backed, and intentionally still a root container."
tags: [productivity, backup]
---
Nextcloud runs from the upstream chart with its own MariaDB/Redis dependencies and an NFS PVC. The official entrypoint writes Apache configuration as root even with `APACHE_PORT` set; de-rooting it would require a custom Apache config and is not worth the divergence.

Its route is behind geoblock, CrowdSec, and Authelia. The PVC is `auto-backup=true`.
