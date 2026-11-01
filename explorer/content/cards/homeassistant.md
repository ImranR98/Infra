---
id: srv0/apps/home/homeassistant
title: Home Assistant
summary: "The home automation hub. Chart-managed, with ConBee/Bluetooth through the device plugin and Frigate/MQTT integrations."
tags: [home, backup, auth]
---
Home Assistant is the one approved third-party chart. Its integrations are declarative: the Frigate integration and Advanced Camera Card are downloaded at pod start, and MQTT discovery creates camera/event entities from Mosquitto.

The ConBee II and Bluetooth adapter are requested as `infra.local/conbee` and host dbus/HCI resources, not privileged mounts. The pod only gets `spc_t` and NET_ADMIN/NET_RAW when those hardware toggles are enabled. The route has no Authelia forward-auth; Home Assistant has its own login and companion apps.
