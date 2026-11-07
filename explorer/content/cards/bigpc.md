---
id: target/bigpc
title: bigpc
summary: "Optional K3s worker; advertises the RX 9070 and runs llama.cpp."
tags: [context, gpu]
---
bigpc is not one of the two subjects. It appears because it can supply an AMD RX 9070 as `infra.local/amd-dgpu`, which lets Immich ML or llama.cpp run on a discrete GPU. It is tainted `scheduling-discouraged` and pinned by its local data PV. Its Compose stack is out of scope.

The llama.cpp router keeps its GGUFs in a cache on the models PV; download and delete them through the built-in Models page at `models.<SERVICES_DOMAIN>`.
