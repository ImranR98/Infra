---
id: srv0/base/host-volumes
title: Host paths
summary: "Static PV/PVC pairs that expose the Main tree to the pods that need a specific host directory."
tags: [storage, cluster]
---
These are the deliberate exceptions to dynamic NFS storage: media libraries, the W@TXT tree, the FL0W pipeline tree, and the journal. Each PV is pinned by `infra.local/hostpath-main` (or `external-exposed` for the journal) and paired with a PVC in the consuming namespace.

Bigpc's AI data (`~/ai/llama`, `~/ai/comfyui`) is host-local Compose data, not a cluster PV.

The claim, not a pod selector, does the scheduling. `hostpath-main` is a singleton: exactly one node owns the Main tree.
