---
id: target/bigpc
title: bigpc
summary: "Compose desktop: llama.cpp on the RX 9070, a FL0W Ludusavi agent, and syncthing."
tags: [context, gpu]
---
bigpc is not one of the two subjects and no longer a Kubernetes node. It runs a Compose stack that supplies the one workload the cluster still depends on: llama.cpp on the AMD RX 9070 (ROCm). `srv0` Traefik reaches it over the LAN through a selectorless `llama-cpp` Service and EndpointSlice at `BIGPC_HOST`, so `models.<SERVICES_DOMAIN>` keeps working publicly, on the VPN, and on the LAN. Everything behind that hostname stays behind Authelia; the raw container port is LAN-only.

The router keeps its GGUFs in `~/ai/llama` (`LLAMA_CACHE`); download and delete them through the built-in Models page at `models.<SERVICES_DOMAIN>`. The FL0W game-save agent runs in the same Compose project and keeps its state under `~/infra_state/compose_live_state/fl0w-agent/`; FL0W on `srv0` reaches it at `http://<bigpc-ip>:8788` over the LAN.

ComfyUI runs in Compose on `pc` (loopback-only). bigpc no longer runs Falco, CrowdSec, or node-exporter: those follow the K3s node, which is `srv0`.
