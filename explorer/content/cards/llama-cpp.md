---
id: srv0/apps/tools/llama-cpp
title: llama.cpp router
summary: "The LLM router runs in Compose on bigpc; this component keeps the stable in-cluster address, the egress rules, and the models route."
tags: [tools, gpu, auth]
facts:
  - label: Backend
    value: Compose on bigpc · RX 9070 (ROCm)
  - label: Address
    value: BIGPC_HOST:8080
  - label: Route
    value: models.<SERVICES_DOMAIN>
  - label: Clients
    value: open-webui · opencode
---
The router is not a pod. `llama-cpp` is a selectorless Service plus a hand-written EndpointSlice pointing at bigpc's LAN address (`BIGPC_HOST`), so in-cluster clients keep using `http://llama-cpp.apps.svc.cluster.local:8080` and srv0 Traefik can serve `models.<SERVICES_DOMAIN>`. The same hostname works publicly, on the VPN, and on the LAN.

The backend is the Compose `llama-cpp` service in `targets/bigpc/compose/compose.yaml` (ROCm, with `~/ai/llama` as `LLAMA_CACHE`). Models are downloaded and deleted through the built-in Models page; do not add `--models-preset` or manual GGUF paths to the router.

The route keeps geoblock, CrowdSec, and Authelia forward-auth. open-webui and opencode are the only in-cluster consumers, each with an explicit egress allow to `BIGPC_HOST:8080`. If bigpc's DHCP lease changes, update `BIGPC_HOST` in `config/srv0/values.yaml` and re-apply.
