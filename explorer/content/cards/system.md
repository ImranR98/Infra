---
id: system
title: Infra guided tours
summary: "Eight linear tours of srv0 and vps0. Facts come from the repo; the notes explain the why."
tags: [primary]
---
The tours are compiled from the actual files: Helm renders, Compose services, Kubernetes resources, scripts, config key usage, workflows, and Renovate rules. Every diagram card is backed by a source file.

The subject is **two machines**:

- `vps0` is the public edge. It terminates public TLS, runs the SSO and threat-response stack, and forwards home traffic over the public-exposure WireGuard tunnel.
- `srv0` is the home cluster. K3s runs the platform and app catalog; a Compose sidecar owns the tunnel client.

`bigpc` appears only as an optional GPU worker inside srv0's cluster. `rpi` appears only as an optional camera source inside Frigate. `pc` is mentioned in passing as another Compose target. Everything else in the repo exists to support these two machines.

**How to use the tours:** pick a tour, read the chapter panel, click a card to inspect it, and use Continue to advance. Code explained opens the implementing files.
