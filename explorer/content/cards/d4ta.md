---
id: srv0/apps/d4ta/d4ta-flow
title: D4TA
summary: "One suite behind data.<domain>: the home dashboard, D$CPLN, W@TXT, FL0W and TAG5, with one repo, one config checkout and one Helm chart."
tags: [d4ta, flow, backup, storage, pipelines]
---
D4TA is one host with one repository, one private `d4ta-config` checkout and one Helm chart, but each module is still its own Deployment at `data.<SERVICES_DOMAIN>/<module>`. The home dashboard serves `/`, D$CPLN `/dscpln`, W@TXT `/watxt`, FL0W `/flow`, TAG5 `/tags` and Lockdown `/lockdown`.

FL0W is the only module that runs as root by design: it needs to read Postgres/Redis-owned PVC data for backups. User-data tasks drop to `MY_UID` through their `run_as` field. The pod uses `spc_t` for the hostPath config checkout and `s0` for the Main tree.

The config repo supplies `apps/flow/config.mjs`, pipeline jobs, tools and runtime state. Task jobs and pipeline jobs share the unified `/api/jobs` model; the complete legacy views stay at `/tasks/` and `/pipelines/`. The backup task is backup-only; restore is `scripts/state-restore.sh`, deliberately outside the app so a fresh cluster can recover.

The chart is published to `oci://ghcr.io/imranr98/charts/d4ta` and pinned by the `srv0-apps` chart dependency. Infra keeps the hostPath config/ledger/media claims, the Gateway/certificates and the middleware names; the app repo owns the Deployments, Services, NetworkPolicies, PodMonitor and the single HTTPRoute.
