---
id: srv0/base/host-volumes
title: Host paths
summary: "Static PV/PVC pairs that expose the Main tree to the pods that need a specific host directory."
tags: [storage, cluster]
---
These are the deliberate exceptions to dynamic NFS storage: media libraries, the WhatsApp TXT tree, the file-pipeline tree, the journal, the Infra checkout, and the code sandbox. Each PV is pinned by `infra.local/hostpath-main` (or `external-exposed` for the journal) and paired with a PVC in the consuming namespace.

The claim, not a pod selector, does the scheduling. `hostpath-main` is a singleton: exactly one node owns the Main tree.
