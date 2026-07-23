## Longhorn Storage

Backs all PVCs previously served by the NFS `/k3s-state` export.

### Replica Policy

Passive is the default replica count. This is safe on a single-node cluster.
**Do not increase replicas beyond the number of healthy nodes.**

- 1 node:    replica = 1   (this cluster)
- 2 nodes:   replica ≤ 2
- 3+ nodes:  replica ≤ 3

Setting `replica > node count` causes volumes to get stuck in the
"Degraded" state — Longhorn cannot schedule the Nth replica without an
Nth node. PVCs remain functional in degraded mode, but the Longhorn UI
will scream and volume health flips yellow.

If you scale to multi-node, update `defaultReplicaCount` in this
HelmChart and consult the backup rotation strategy.

### Access Mode

All PVCs use `ReadWriteOnce`. Cross-node pod moves are handled by
Longhorn's automatic detach/reattach (~30s). If a Deployment needs
`replicas > 1` on a shared volume in the future, convert that specific
PVC to `ReadWriteMany` — Longhorn will spin up a share-manager for it.
