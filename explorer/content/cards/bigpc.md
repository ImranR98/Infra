---
id: target/bigpc
title: bigpc
summary: "Compose desktop: llama.cpp on the RX 9070, a D4TA Wine game-save archive agent, and syncthing."
tags: [context, gpu]
---
bigpc is not one of the two subjects; it is a Compose host, not a Kubernetes node. It runs a Compose stack that supplies the one workload the cluster still depends on: llama.cpp on the AMD RX 9070 (ROCm). `srv0` Traefik reaches it over the LAN through a selectorless `llama-cpp` Service and EndpointSlice at `BIGPC_HOST`, so `models.<SERVICES_DOMAIN>` keeps working publicly, on the VPN, and on the LAN. Everything behind that hostname stays behind Authelia; the raw container port is LAN-only.

The router keeps its GGUFs in `~/ai/llama` (`LLAMA_CACHE`); download and delete them through the built-in Models page at `models.<SERVICES_DOMAIN>`. The D4TA game-save agent runs in the same Compose project and keeps its state under `~/infra_state/compose_live_state/d4ta-agent/`; D4TA on `srv0` reaches it at `http://<bigpc-ip>:8788` over the LAN.

ComfyUI runs in Compose on `pc` (loopback-only). Falco, CrowdSec, and node-exporter run only on the K3s node, `srv0`.
