---
id: decision/auth/geoblock-api
title: Geoblock uses a public API
appliesTo:
  - srv0/base/traefik
  - vps0/service/traefik
---
The Traefik geoblock plugin calls `get.geojs.io` and fails closed. A geojs outage blocks public traffic. That tradeoff removed the self-hosted GeoIP service, image, update secret, and init container.

Authelia deliberately sits outside geoblock so the operator can travel. The six apps with their own login and a few public-by-design services are also explicit exceptions; don't add geoblock to them without accepting the guest-country constraint.
