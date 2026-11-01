---
id: srv0/apps/tools/opencode
title: opencode
summary: "A sandboxed in-cluster coding agent. NFS home, unbacked tools volume, and a single shared code mount."
tags: [tools, auth]
---
opencode is intentionally constrained: it can write to its own home PVC, its toolchain volume, and `Main/Code/sandbox` — nothing else on the host. The image is a derived sandbox with the glibc binary, Node, and a Homebrew seed.

The home PVC is backed up; the tools PVC is not, because it is reproducible. The route is public behind geoblock, CrowdSec, and Authelia.
