# Infra Explorer

A build-time graph of the Infra repo, presented as a library of linear guided tours. There is no free-exploration atlas.

Requires Node.js 18+ and npm.

```bash
npm install
npm run dev        # generate the map, then start Vite
npm run check      # regenerate + typecheck + validate the map and tours
npm run build      # static build
npm run preview    # serve the build locally
```

## Tours

The default screen is the tour library. Each tour is linear: a chapter panel, a focused diagram, and Back/Continue. Progress is stored per tour in `localStorage`.

| Tour | Covers |
|---|---|
| **Start here** (recommended) | The request path: vps0, per-router auth, WireGuard basics, the tunnel, the srv0 Gateway, Immich, and NFS |
| **The public edge** | vps0 routing, CrowdSec/geoblock/Authelia per router, and the shared srv0 certificates |
| **WireGuard** | Point-to-point tunnel addresses, public-exposure DNAT, the AmneziaWG VPN, and preboot unlock |
| **Apps and data** | The K3s split, app catalog, Immich, authentication, hardware resources, contextual machines, NFS, and backups |
| **Keeping it running** | Renovate, CI, schedules, State Backups, Grafana/Falco, and NetworkPolicy/SELinux isolation |
| **Configuration and decisions** | The working tree, config layers, and accepted tradeoffs |
| **First boot** | DNS, prerequisites, config, tunnel material, vps0, srv0, optional nodes, verification, and manual setup |
| **Maintenance** | Motherboard swap, NFS storage, Guacamole/Windows, and restic recovery |

Every chapter has a **Code explained** list that opens the relevant files in the source viewer.

## Content

- `content/story.yaml` — chapters, copy, per-chapter flow columns, zones, edges, and code lists.
- `content/tours.yaml` — ordered chapter lists per tour; one tour must be `recommended`.
- `content/cards/*.md` — node summaries and target facts merged into the generated graph.
- `scripts/build-map.mjs` — compiles the graph from Helm renders, Compose services, Kubernetes resources, scripts, workflows, timers, and `renovate.json`. It also computes node positions and zone bounds from each chapter's `flow` and `zones`.
- `scripts/check-map.mjs` — validates every tour, chapter, edge, code path, node bound, zone bound, and node overlap.

The graph is compiled from tracked files. Source files are indexed into `public/snippets/` for the viewer; generated output under `public/` is ignored.

Audience: `srv0` and `vps0` are the subject. `bigpc` and `rpi` are contextual only; `pc` is a passing mention.
