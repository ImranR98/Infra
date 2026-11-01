---
id: srv0/apps/media/immich
title: Immich
summary: "The photo and video library. A chart-managed app split into server, ML, Postgres, Valkey, and two storage claims."
tags: [media, gpu, auth, backup]
facts:
  - label: Exposure
    value: public route + app auth
  - label: ML backend
    value: OpenVINO / ROCm / CPU by GPU_PROFILE
  - label: Storage
    value: NFS primary library + media host path
---
Immich is the best example of why the graph is hierarchical. The template owns the HelmChart, route, NetworkPolicies, database credentials, two PVCs, and the seed hook. The chart itself owns the server, machine-learning, Postgres, Valkey, and their internal wiring.

Things worth noticing:

- The server uses the vendor-neutral `infra.local/vaapi` resource; ML uses `intel-gpu` or bigpc's `amd-dgpu` depending on `GPU_PROFILE`.
- The database PVC is `auto-backup=true`; the library PVC is not — it is the primary photo store on NFS and is backed up by the storage layer's own policy.
- The route uses geoblock and CrowdSec, but not Authelia forward-auth. Immich has its own login and an Authelia OIDC client.
- The seed hook creates the first admin through the sign-up API and stores the generated password in a Secret.
