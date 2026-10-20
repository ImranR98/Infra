> **Historical:** this records the 2026 Longhorn -> NFS migration. The legacy `scripts/pvc.sh` tar backup/restore commands below no longer exist; use `scripts/restic-restore.sh` for current restores.

# Runbook: NFS storage migration (Longhorn → NFS)

This is the procedure that was used for the full migration; keep it for future storage moves.

1. **Freeze/scale down.** Scale all Longhorn-backed workloads to zero (`apps` Deployments/StatefulSets and the base consumers). Wait for pods to terminate.
2. **Back up every PVC.** With the workloads stopped:
   ```bash
   names=$(kubectl get pvc -A -o json | jq -r '.items[] | select(.spec.storageClassName=="longhorn") | .metadata.name')
   for n in $names; do
     PVC_POD_UID=0 PVC_BACKUP_TIMEOUT=7200 PVC_BACKUP_THROTTLE=0 \
       bash scripts/pvc.sh backup "$n" -y
   done
   ```
   The backup pod runs as root; archives land in `k3s_state_backups`.
3. **Save the old specs.** `kubectl get pvc -A -o json > /tmp/pvcs-before.json`.
4. **Delete the old PVCs while retaining the PVs** (`persistentVolumeReclaimPolicy: Retain`), then create the replacements with `storageClassName: nfs-apps`, `ReadWriteMany`, and the same name/namespace/labels/size. The `nfs-apps` SC creates `${ns}/${pvc}` under `current_target/k3s_live_state/nfs-apps`.
5. **Restore every PVC.** `PVC_POD_UID=0 PVC_RESTORE_TIMEOUT=7200 bash scripts/pvc.sh restore "$n" -y`. The restore pod runs as root and uses `tar --numeric-owner`; the restore loop scales workloads to 0 (they are already 0) and leaves them 0.
6. **Apply the charts.** Delete the old chart-managed StatefulSet if its `volumeClaimTemplates` stored the old class (the Loki StatefulSet was recreated), then `helm upgrade --install srv0-base ...` and `srv0-apps ...`; scale the chart-managed app Deployments back to their desired replicas.
7. **Longhorn removal.** Delete the old PVs, Longhorn volumes, SCs (`longhorn`, `longhorn-static`), CRDs, the `longhorn-system` namespace, and the Longhorn validating/mutating webhooks. If the namespace is stuck `Terminating` on the `longhorn-admission-webhook` service, delete the webhook configurations and the finalizers/CRDs, then finalize the namespace. NFD/node-facts are removed the same way (CRDs/namespace) and the static labels set with `kubectl label node srv0 infra.local/hostpath-main=true infra.local/external-exposed=true --overwrite`.
8. **Make `nfs-apps` default.**
   ```bash
   kubectl annotate sc nfs-apps storageclass.kubernetes.io/is-default-class=true --overwrite
   ```
9. **Fix ownership where the restore preserved root-owned files** (e.g. Navidrome): a temporary root pod can `chown -R 1000:1000` the app's data. The Authelia Postgres init container chowns its own DB.
10. **Immich Postgres.** The image refuses NFS unless `IGNORE_DATABASE_FSTYPE=true` is set on the Postgres container (already in `immich.yaml`).
11. **Verify.** `kubectl get pvc -A` all Bound; `kubectl get pods -A`; `bash scripts/validate.sh srv0`; test one backup/restore and the Jellyfin/Immich/Nextcloud/Linkwarden logins.

Expected tradeoff: NFS SQLite/Postgres latency is higher than the old block storage (the benchmark measured ~3× SQLite p95 and ~2.6× Postgres under load). Backups remain tar archives, not Longhorn snapshots.
