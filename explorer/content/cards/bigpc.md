---
id: target/bigpc
title: bigpc
summary: "Optional K3s worker; advertises the RX 9070 and runs Ollama."
tags: [context, gpu]
---
bigpc is not one of the two subjects. It appears because it can supply an AMD RX 9070 as `infra.local/amd-dgpu`, which lets Immich ML or Ollama run on a discrete GPU. It is tainted `scheduling-discouraged` and pinned by its local data PV. Its Compose stack is out of scope.
