---
id: srv0/base/host-volumes
title: Host paths
summary: "Static PV/PVC pairs that expose the Main tree to the pods that need a specific host directory."
tags: [storage, cluster]
---
These are the deliberate exceptions to dynamic NFS storage: media libraries, the W@TXT tree, the FL0W pipeline tree, the journal, and the AI data root. Each PV is pinned by `infra.local/hostpath-main` (or `external-exposed` for the journal) and paired with a PVC in the consuming namespace.

`ai-data-pv` is the AI-data exception: `<HOME_DIR>/ai` on bigpc, pinned by `kubernetes.io/hostname=bigpc`, shared by llama.cpp (`subPath: llama`) and ComfyUI (`subPath: comfyui`). It is local desktop data, not a GPU selector.

The claim, not a pod selector, does the scheduling. `hostpath-main` is a singleton: exactly one node owns the Main tree.
