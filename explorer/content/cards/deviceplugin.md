---
id: srv0/base/generic-device-plugin
title: Hardware resources
summary: "The generic device plugin turns sysfs/devices into schedulable extended resources: GPU, VAAPI, and ConBee."
tags: [cluster, gpu]
---
The plugin scans each node at startup and advertises hardware as resources, not node labels: `infra.local/intel-gpu`, `amd-igpu`, `amd-dgpu`, `vaapi`, and `conbee`. It normalizes device names to `renderD128`/`card0`/`ttyACM0`, so a workload never depends on enumeration order.

This is why Immich, Frigate, Jellyfin, Ollama, and Home Assistant can request exactly the capability they need without `privileged: true`. `GPU_PROFILE` chooses the media/ML backend; per-app overrides handle mixed hardware.
