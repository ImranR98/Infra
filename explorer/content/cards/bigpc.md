---
id: target/bigpc
title: bigpc
summary: "Opt-in-only K3s worker; advertises the RX 9070 and runs llama.cpp and ComfyUI."
tags: [context, gpu]
---
bigpc is not one of the two subjects. It appears because it supplies an AMD RX 9070 as `infra.local/amd-dgpu`, which lets Immich ML, llama.cpp, and ComfyUI run on a discrete GPU. It is tainted `infra.local/noschedule=true:NoSchedule`, so only workloads that explicitly tolerate the taint run there: the node-agent DaemonSets, llama.cpp, ComfyUI, Immich ML (AMD dGPU branch), and the bigpc FL0W agent. Platform services and normal apps never tolerate it.

The AI tools share `ai-data-pv` / `ai-data-pvc`, a hostname-pinned hostPath under `<HOME_DIR>/ai`. llama.cpp mounts `subPath: llama`; ComfyUI mounts `subPath: comfyui`. Its Compose stack is out of scope.

The llama.cpp router keeps its GGUFs in the `llama` subPath; download and delete them through the built-in Models page at `models.<SERVICES_DOMAIN>`. ComfyUI uses `comfyui.<SERVICES_DOMAIN>`.
