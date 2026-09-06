# lib/pvc.sh — shared PVC backup/restore utilities
# Sourced by lib/common.sh. All functions take explicit parameters.

# pvc_find_namespace <pvc-name> → namespace (stdout)
# Queries all namespaces. Returns empty if not found.
pvc_find_namespace() {
    local name="${1:?}"
    kubectl get pvc -A -o json 2>/dev/null | \
        jq -r --arg name "$name" \
        '.items[] | select(.metadata.name == $name) | .metadata.namespace' 2>/dev/null || true
}

# pvc_release_pv <pvc-name> <namespace>
# Clears claimRef.uid on Released PVs that reference the PVC, making them Available.
pvc_release_pv() {
    local pvc_name="${1:?}" ns="${2:?}"
    kubectl get pv -o json 2>/dev/null | jq -r --arg name "$pvc_name" --arg ns "$ns" \
        '.items[] | select(.status.phase == "Released" and .spec.claimRef.name == $name and .spec.claimRef.namespace == $ns) | .metadata.name' \
        | while read -r pv; do
            kubectl patch pv "$pv" --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' 2>/dev/null || true
        done
}

# pvc_find_workloads <namespace> <pvc-name> → "kind/name" per line (stdout)
# Finds Deployments + StatefulSets referencing the PVC. Skips DaemonSets.
pvc_find_workloads() {
    local ns="${1:?}" pvc="${2:?}"
    kubectl get deploy,sts -n "$ns" -o json 2>/dev/null | \
        jq -r --arg pvc "$pvc" \
        '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | "\(.kind)/\(.metadata.name)"' 2>/dev/null || true
}

# pvc_scale_down <namespace> <pvc-name> <scaled-file>
# Records replica counts to scaled-file, scales each workload to 0.
# Writes "namespace/kind/name/replicas" lines. Returns 0 if any scaled, 1 if none.
pvc_scale_down() {
    local ns="${1:?}" pvc="${2:?}" scaled_file="${3:?}"
    local workloads kind wname reps did_scale=false
    workloads=$(pvc_find_workloads "$ns" "$pvc")
    for w in $workloads; do
        kind="${w%%/*}"
        wname="${w##*/}"
        reps=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
        echo "$ns/$kind/$wname/$reps" >> "$scaled_file"
        if [ "$reps" != "0" ]; then
            kubectl scale "$kind" "$wname" -n "$ns" --replicas=0
            did_scale=true
        fi
    done
    $did_scale
}

# pvc_wait_pods_gone <scaled-file>
# Reads scaled-file (ns/kind/name/reps format), waits for pods to terminate.
# Warns on timeout but does not abort.
pvc_wait_pods_gone() {
    local scaled_file="${1:?}"
    [ -f "$scaled_file" ] || return 0
    while IFS= read -r entry; do
        local ns kind wname selector
        ns=$(echo "$entry" | cut -d/ -f1)
        kind=$(echo "$entry" | cut -d/ -f2)
        wname=$(echo "$entry" | cut -d/ -f3)
        selector=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | \
            jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        [ -n "$selector" ] || continue
        if ! kubectl wait --for=delete pod -n "$ns" --selector="$selector" --timeout=180s 2>/dev/null; then
            echo "WARNING: pods for $ns/$kind/$wname did not terminate within 180s" >&2
        fi
    done < "$scaled_file"
}

# pvc_wait_bound <namespace> <pvc-name>
# Retry-loops until PVC phase is Bound. Returns non-zero on timeout.
pvc_wait_bound() {
    local ns="${1:?}" pvc="${2:?}" timeout="${3:-150}"
    local max_tries=$(( timeout / 5 ))
    for _ in $(seq 1 "$max_tries"); do
        local status
        status=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "$status" = "Bound" ] && return 0
        sleep 5
    done
    echo "Error: PVC $pvc did not become Bound within ${timeout}s" >&2
    return 1
}

# pvc_scale_restore <scaled-file>
# Reads scaled-file (ns/kind/name/reps format), restores each workload.
pvc_scale_restore() {
    local scaled_file="${1:?}"
    [ -f "$scaled_file" ] || return 0
    while IFS= read -r entry; do
        local ns kind wname reps
        ns=$(echo "$entry" | cut -d/ -f1)
        kind=$(echo "$entry" | cut -d/ -f2)
        wname=$(echo "$entry" | cut -d/ -f3)
        reps=$(echo "$entry" | cut -d/ -f4)
        echo "Restoring $ns/$kind/$wname to $reps replicas..."
        kubectl scale "$kind" "$wname" -n "$ns" --replicas="$reps" 2>/dev/null || \
            echo "WARNING: failed to restore $ns/$kind/$wname — it may still be scaled to 0" >&2
    done < "$scaled_file"
}

# pvc_volume_node <pvc-name> <namespace> → node name hosting the volume (stdout)
# Maps PVC → PV → CSI volume handle → Longhorn volume currentNodeID.
# Returns empty for non-Longhorn volumes, unattached volumes, or query errors.
pvc_volume_node() {
    local pvc="${1:?}" ns="${2:?}"
    local pv_name handle
    pv_name=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    [ -n "$pv_name" ] || return 0
    handle=$(kubectl get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
    [ -n "$handle" ] || return 0
    kubectl -n longhorn-system get volume "$handle" -o jsonpath='{.status.currentNodeID}' 2>/dev/null || true
}

# pvc_node_ready <node> → 0 if the node reports Ready=True, 1 otherwise.
pvc_node_ready() {
    local node="${1:?}"
    local ready
    ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$ready" = "True" ]
}

# pvc_ensure_backup_dest <namespace>
# Ensures the shared RWX NFS PVC used as the backup destination exists and is
# Bound in the given namespace. The PVC binds to the static PV
# pvc-backup-dest-pv, which mounts the ROOT of the NFS backups share
# ($PVC_BACKUP_DIR on the hostpath-main node) — archives are written directly
# to their final human-named path, reachable from any node.
pvc_ensure_backup_dest() {
    local ns="${1:?}"
    if ! kubectl get pvc pvc-backup-dest -n "$ns" >/dev/null 2>&1; then
        kubectl apply -f - <<PVC_EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-backup-dest
  namespace: $ns
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: nfs-backup
PVC_EOF
    fi
    local max_tries=30
    for _ in $(seq 1 "$max_tries"); do
        if [ "$(kubectl get pvc pvc-backup-dest -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ]; then
            return 0
        fi
        sleep 2
    done
    echo "Error: pvc-backup-dest in $ns did not become Bound (is the pvc-backup-dest-pv static PV present?)" >&2
    return 1
}

# pvc_backup_pod_yaml <pvc-name> <namespace> <backup-dir> <dest-file> <timestamp> [exclude-patterns] [node]
# Prints the backup pod YAML to stdout. Caller pipes to kubectl apply.
# exclude-patterns: optional space-separated tar --exclude patterns (e.g. "index-*.db")
# node: optional node name; the pod is scheduled there (RWO volumes must be
# mounted where they're currently attached — scheduling elsewhere would force
# a cross-node Longhorn migration that can hang while the workload holds it).
# <backup-dir> is accepted for signature compatibility but no longer used:
# the archive is written to the shared pvc-backup-dest NFS PVC at /backup.
pvc_backup_pod_yaml() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" dest_file="${4:?}" timestamp="${5:?}"
    local exclude="${6:-}" node="${7:-}"
    local pod_name
    pod_name="backup-$(echo "$pvc" | tr '_' '-')"
    local excl_flags=""
    if [ -n "$exclude" ]; then
        for pat in $exclude; do
            excl_flags="$excl_flags --exclude=$pat"
        done
    fi
    local node_selector=""
    local tolerations=""
    if [ -n "$node" ]; then
        node_selector="  nodeSelector:
    kubernetes.io/hostname: $node"
        # Tolerate the PreferNoSchedule taint used on desktop nodes (bigpc).
        tolerations="  tolerations:
    - key: scheduling-discouraged
      operator: Exists
      effect: PreferNoSchedule"
    fi
    cat <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  namespace: $ns
  labels:
    app: pvc-backup-temp
spec:
  securityContext:
    runAsUser: ${MY_UID}
    runAsGroup: ${MY_UID}
    fsGroup: ${MY_UID}
    seLinuxOptions:
      level: "s0"
  restartPolicy: Never
$node_selector
$tolerations
  containers:
  - name: backup
    image: debian:bookworm-slim
    command:
    - sh
    - -c
    - |
      echo "$timestamp" > /data/__backup_timestamp.txt
      if ! tar czf "/backup/.$dest_file.tmp" -C /data $excl_flags --sparse --warning=no-file-changed --warning=no-file-removed --ignore-failed-read .; then
        echo "ERROR: tar archive creation failed" >&2
        rm -f "/backup/.$dest_file.tmp" /data/__backup_timestamp.txt
        exit 1
      fi
      if [ ! -s "/backup/.$dest_file.tmp" ]; then
        echo "ERROR: backup archive is empty" >&2
        rm -f "/backup/.$dest_file.tmp" /data/__backup_timestamp.txt
        exit 1
      fi
      mv "/backup/.$dest_file.tmp" "/backup/$dest_file"
      rm -f /data/__backup_timestamp.txt
    volumeMounts:
    - name: data
      mountPath: /data
    - name: backup-dest
      mountPath: /backup
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc
  - name: backup-dest
    persistentVolumeClaim:
      claimName: pvc-backup-dest
PODEOF
}

# pvc_restore_pod_yaml <pvc-name> <namespace> <backup-dir> <src-file>
# Prints the restore pod YAML to stdout. Caller pipes to kubectl apply.
pvc_restore_pod_yaml() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" src_file="${4:?}"
    local pod_name
    pod_name="restore-$(echo "$pvc" | tr '_' '-')"
    cat <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  namespace: $ns
  labels:
    app: pvc-restore-temp
spec:
  securityContext:
    runAsUser: ${MY_UID}
    runAsGroup: ${MY_UID}
    fsGroup: ${MY_UID}
    seLinuxOptions:
      level: "s0"
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.21
    securityContext:
      # Not privileged: deleting root-owned files inside the PVC needs
      # CAP_DAC_OVERRIDE/CAP_FOWNER (the pod runs as $MY_UID); spc_t covers
      # SELinux labels left by older pods.
      allowPrivilegeEscalation: false
      capabilities:
        add:
          - DAC_OVERRIDE
          - FOWNER
      seLinuxOptions:
        type: spc_t
        level: s0
    command:
    - sh
    - -c
    - |
      if ! mountpoint /data; then
        echo "ERROR: PVC not mounted at /data" >&2
        exit 1
      fi
      find /data -mindepth 1 -delete
      tar xzf /backup/"$src_file" -C /data
    volumeMounts:
    - name: data
      mountPath: /data
    - name: backup-src
      mountPath: /backup
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc
  - name: backup-src
    persistentVolumeClaim:
      claimName: pvc-backup-dest
PODEOF
}

# pvc_backup_data <pvc> <ns> <backup-dir> <dest-file> <timestamp> [exclude]
# Creates backup pod, waits for success, cleans up. Returns 0 on success.
# <backup-dir> is accepted for signature compatibility but no longer used:
# the archive is written directly to its final name via the shared
# pvc-backup-dest volume.
pvc_backup_data() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" dest_file="${4:?}" timestamp="${5:?}" exclude="${6:-}"
    local pod_name node
    pod_name="backup-$(echo "$pvc" | tr '_' '-')"

    # Schedule the backup pod on the node currently hosting the volume (RWO).
    # Fail fast if that node is not Ready instead of hanging in ContainerCreating
    # for the full wait timeout.
    node=$(pvc_volume_node "$pvc" "$ns")
    if [ -n "$node" ]; then
        if ! pvc_node_ready "$node"; then
            echo "  ERROR: volume for $ns/$pvc is attached to node '$node' which is not Ready; skipping" >&2
            return 1
        fi
        echo "  Volume hosted on node $node — backup pod scheduled there"
    fi

    # Archive destination is a shared NFS PVC so any node can write it.
    if ! pvc_ensure_backup_dest "$ns"; then
        echo "  ERROR: could not prepare backup destination for $ns/$pvc" >&2
        return 1
    fi

    pvc_backup_pod_yaml "$pvc" "$ns" "$backup_dir" "$dest_file" "$timestamp" "$exclude" "$node" | kubectl apply -f -
    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod_name" -n "$ns" --timeout=900s 2>/dev/null; then
        echo "  ERROR: backup pod failed for $ns/$pvc" >&2
        echo "  --- pod status ---" >&2
        kubectl describe pod "$pod_name" -n "$ns" 2>&1 || true
        echo "  --- pod logs ---" >&2
        kubectl logs "pod/$pod_name" -n "$ns" --tail=100 2>&1 || true
        kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true
        return 1
    fi
    kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true

    # The archive is written directly to its final name inside the shared
    # pvc-backup-dest volume (the ROOT of the NFS backups share), so there is
    # nothing to move after the pod succeeds.
    return 0
}

# pvc_backup_all <auto-yes>
# Backs up every PVC with label auto-backup=true.
# Skips the confirmation prompt when auto_yes=true.
pvc_backup_all() {
    local auto_yes="${1:-false}"
    local backup_dir="${PVC_BACKUP_DIR:?PVC_BACKUP_DIR not set}"
    local total=0 failed=0
    local pvc_list timestamp ns name exclude workloads

    mkdir -p "$backup_dir"
    chcon -t container_file_t -l s0 "$backup_dir" 2>/dev/null || true

    timestamp=$(date -Iseconds)

    kubectl delete pod -A -l app=pvc-backup-temp --wait=false 2>/dev/null || true

    pvc_list=$(kubectl get pvc -A -l auto-backup=true -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if [ -z "$pvc_list" ]; then
        echo "No PVCs found with label auto-backup=true"
        return 0
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"
        total=$((total + 1))

        echo "=== Backing up $ns/$name ($total) ==="

        workloads=$(pvc_find_workloads "$ns" "$name")
        if [ -n "$workloads" ]; then
            echo "  WARNING: these workloads are running — backup captures live state:"
            for w in $workloads; do echo "    $w"; done
        fi

        exclude=$(kubectl get pvc "$name" -n "$ns" -o jsonpath='{.metadata.annotations.backup\.infra/exclude}' 2>/dev/null || echo "")

        if pvc_backup_data "$name" "$ns" "$backup_dir" "${name}.tar.gz" "$timestamp" "$exclude"; then
            echo "  Done: $name"
        else
            failed=$((failed + 1))
        fi
        echo ""
    done <<< "$pvc_list"

    if [ "$failed" -gt 0 ]; then
        echo "=== Backup complete with $failed/$total failures ==="
        return 1
    fi
    echo "=== Backup complete ($total PVCs) ==="
}

# pvc_restore_data <pvc> <ns> <backup-dir> <src-file>
# Creates restore pod, waits for success, cleans up. Returns 0 on success.
# Caller must ensure PVC is Bound before calling.
pvc_restore_data() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" src_file="${4:?}"
    local pod_name
    if ! pvc_ensure_backup_dest "$ns"; then
        echo "  ERROR: could not prepare backup source for $ns/$pvc" >&2
        return 1
    fi
    pod_name="restore-$(echo "$pvc" | tr '_' '-')"
    pvc_restore_pod_yaml "$pvc" "$ns" "$backup_dir" "$src_file" | kubectl apply -f -
    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod_name" -n "$ns" --timeout=900s 2>/dev/null; then
        echo "  ERROR: restore pod failed for $ns/$pvc" >&2
        kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true
        return 1
    fi
    kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true
    return 0
}

# pvc_restore_all <auto-yes>
# Restores every PVC with label auto-backup=true that has an existing backup archive.
# Bulk scales down all workloads first, restores each PVC, then scales back up.
# Skips the confirmation prompt when auto_yes=true.
pvc_restore_all() {
    local auto_yes="${1:-false}"
    local backup_dir="${PVC_BACKUP_DIR:?PVC_BACKUP_DIR not set}"
    local total=0 failed=0 skipped=0
    local pvc_list ns name backup_file timestamp
    local scaled_file_all

    pvc_list=$(kubectl get pvc -A -l auto-backup=true -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if [ -z "$pvc_list" ]; then
        echo "No PVCs found with label auto-backup=true"
        return 0
    fi

    scaled_file_all=$(mktemp)

    # Phase 1 — bulk scale-down across all matching PVCs
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"

        backup_file="$backup_dir/${name}.tar.gz"
        if [ ! -f "$backup_file" ] || [ ! -s "$backup_file" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        pvc_scale_down "$ns" "$name" "$scaled_file_all"
    done <<< "$pvc_list"

    if [ -s "$scaled_file_all" ]; then
        echo "Waiting for all pods to terminate..."
        pvc_wait_pods_gone "$scaled_file_all"
    fi

    # Phase 2 — restore each PVC
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"

        backup_file="$backup_dir/${name}.tar.gz"
        [ -f "$backup_file" ] || continue
        total=$((total + 1))

        echo "=== Restoring $ns/$name ($total) ==="

        pvc_wait_bound "$ns" "$name" 150 || { failed=$((failed + 1)); continue; }

        timestamp=$(tar xzf "$backup_file" __backup_timestamp.txt -O 2>/dev/null || echo "unknown")
        echo "  Restoring from backup taken at: $timestamp"

        if pvc_restore_data "$name" "$ns" "$backup_dir" "${name}.tar.gz"; then
            echo "  Done: $name"
        else
            failed=$((failed + 1))
        fi
        echo ""
    done <<< "$pvc_list"

    # Phase 3 — bulk scale-up
    if [ -s "$scaled_file_all" ]; then
        echo "Restoring all workloads..."
        pvc_scale_restore "$scaled_file_all"
    fi

    rm -f "$scaled_file_all"

    if [ "$skipped" -gt 0 ]; then
        echo "=== Skipped $skipped PVCs (no backup file found) ==="
    fi
    if [ "$failed" -gt 0 ]; then
        echo "=== Restore complete with $failed/$total failures ==="
        return 1
    fi
    echo "=== Restore complete ($total PVCs) ==="
}
