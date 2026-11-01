---
id: srv0/apps/media/frigate
title: Frigate
summary: "The NVR. Raw manifests, recorded media on NFS, MQTT to Home Assistant, and an optional RTSP camera source."
tags: [media, gpu, backup]
facts:
  - label: Detector
    value: OpenVINO (intel-gpu) or ROCm (amd-igpu)
  - label: Recordings
    value: NFS
  - label: Camera source
    value: optional rpi go2rtc
---
Frigate runs as raw manifests, not an upstream chart. That keeps the image, GPU resource, probes, and media PV explicit.

The camera source is deliberately contextual: `rpi` is one possible go2rtc source. It is not a required machine, and the tours only show it here. The Frigate ↔ Home Assistant path goes through Mosquitto; the dashboard and integration are provisioned by Home Assistant.
