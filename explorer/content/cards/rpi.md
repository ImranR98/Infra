---
id: target/rpi
title: rpi
summary: "Pi 400 running go2rtc; Frigate consumes its authenticated RTSP stream."
tags: [context, network]
---
The Pi runs go2rtc and exposes an authenticated RTSP stream. Frigate can consume it, but any RTSP source works. Only the stream contract is in scope; the machine bootstrap and Compose stack are not.
