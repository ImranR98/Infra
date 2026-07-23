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
# Writes "kind/name/replicas" lines. Returns 0 if any scaled, 1 if none.
pvc_scale_down() {
    local ns="${1:?}" pvc="${2:?}" scaled_file="${3:?}"
    local workloads kind wname reps did_scale=false
    workloads=$(pvc_find_workloads "$ns" "$pvc")
    for w in $workloads; do
        kind="${w%%/*}"
        wname="${w##*/}"
        reps=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
        echo "$kind/$wname/$reps" >> "$scaled_file"
        if [ "$reps" != "0" ]; then
            kubectl scale "$kind" "$wname" -n "$ns" --replicas=0
            did_scale=true
        fi
    done
    $did_scale
}

# pvc_wait_pods_gone <namespace> <scaled-file>
# Reads scaled-file, waits for pods of scaled workloads to terminate.
# Warns on timeout but does not abort.
pvc_wait_pods_gone() {
    local ns="${1:?}" scaled_file="${2:?}"
    [ -f "$scaled_file" ] || return 0
    while IFS= read -r entry; do
        local kind wname selector
        kind=$(echo "$entry" | cut -d/ -f1)
        wname=$(echo "$entry" | cut -d/ -f2)
        selector=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | \
            jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        [ -n "$selector" ] || continue
        if ! kubectl wait --for=delete pod -n "$ns" --selector="$selector" --timeout=180s 2>/dev/null; then
            echo "WARNING: pods for $kind/$wname did not terminate within 180s" >&2
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

# pvc_scale_restore <namespace> <scaled-file>
# Reads scaled-file, restores each workload to its original replica count.
pvc_scale_restore() {
    local ns="${1:?}" scaled_file="${2:?}"
    [ -f "$scaled_file" ] || return 0
    while IFS= read -r entry; do
        local kind wname reps
        kind=$(echo "$entry" | cut -d/ -f1)
        wname=$(echo "$entry" | cut -d/ -f2)
        reps=$(echo "$entry" | cut -d/ -f3)
        echo "Restoring $kind/$wname to $reps replicas..."
        kubectl scale "$kind" "$wname" -n "$ns" --replicas="$reps" 2>/dev/null || \
            echo "WARNING: failed to restore $kind/$wname — it may still be scaled to 0" >&2
    done < "$scaled_file"
}

# pvc_backup_pod_yaml <pvc-name> <namespace> <backup-dir> <dest-file> <timestamp> [exclude-patterns]
# Prints the backup pod YAML to stdout. Caller pipes to kubectl apply.
# exclude-patterns: optional space-separated tar --exclude patterns (e.g. "index-*.db")
pvc_backup_pod_yaml() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" dest_file="${4:?}" timestamp="${5:?}"
    local exclude="${6:-}"
    local pod_name
    pod_name="backup-$(echo "$pvc" | tr '_' '-')"
    local excl_flags=""
    if [ -n "$exclude" ]; then
        for pat in $exclude; do
            excl_flags="$excl_flags --exclude=$pat"
        done
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
  restartPolicy: Never
  containers:
  - name: backup
    image: alpine:3.21
    securityContext:
      privileged: true
    command:
    - sh
    - -c
    - |
      echo "$timestamp" > /data/__backup_timestamp.txt
      if ! tar czf /backup/"$dest_file" -C /data $excl_flags .; then
        echo "ERROR: tar archive creation failed" >&2
        rm -f /data/__backup_timestamp.txt
        exit 1
      fi
      rm -f /data/__backup_timestamp.txt
      if [ ! -s /backup/"$dest_file" ]; then
        echo "ERROR: backup archive is empty" >&2
        exit 1
      fi
      chown ${MY_UID}:${MY_UID} /backup/"$dest_file" 2>/dev/null || true
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
    hostPath:
      path: $backup_dir
      type: DirectoryOrCreate
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
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.21
    securityContext:
      privileged: true
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
    hostPath:
      path: $backup_dir
      type: DirectoryOrCreate
PODEOF
}

# pvc_backup_data <pvc> <ns> <backup-dir> <dest-file> <timestamp> [exclude]
# Creates backup pod, waits for success, cleans up. Returns 0 on success.
pvc_backup_data() {
    local pvc="${1:?}" ns="${2:?}" backup_dir="${3:?}" dest_file="${4:?}" timestamp="${5:?}" exclude="${6:-}"
    local pod_name
    pod_name="backup-$(echo "$pvc" | tr '_' '-')"
    pvc_backup_pod_yaml "$pvc" "$ns" "$backup_dir" "$dest_file" "$timestamp" "$exclude" | kubectl apply -f -
    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod_name" -n "$ns" --timeout=600s 2>/dev/null; then
        echo "  ERROR: backup pod failed for $ns/$pvc" >&2
        kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true
        return 1
    fi
    kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null || true
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

        exclude=$(kubectl get pvc "$name" -n "$ns" -o jsonpath='{.metadata.annotations.backup\.atlas/exclude}' 2>/dev/null || echo "")

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
    pod_name="restore-$(echo "$pvc" | tr '_' '-')"
    pvc_restore_pod_yaml "$pvc" "$ns" "$backup_dir" "$src_file" | kubectl apply -f -
    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod_name" -n "$ns" --timeout=600s 2>/dev/null; then
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

        workloads=$(pvc_find_workloads "$ns" "$name")
        for w in $workloads; do
            kind="${w%%/*}"
            wname="${w##*/}"
            reps=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
            echo "$ns/$kind/$wname/$reps" >> "$scaled_file_all"
            if [ "$reps" != "0" ]; then
                kubectl scale "$kind" "$wname" -n "$ns" --replicas=0 2>/dev/null
            fi
        done
    done <<< "$pvc_list"

    if [ -s "$scaled_file_all" ]; then
        echo "Waiting for all pods to terminate..."
        while IFS= read -r entry; do
            ns=$(echo "$entry" | cut -d/ -f1)
            kind=$(echo "$entry" | cut -d/ -f2)
            wname=$(echo "$entry" | cut -d/ -f3)
            selector=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
            [ -n "$selector" ] || continue
            kubectl wait --for=delete pod -n "$ns" --selector="$selector" --timeout=180s 2>/dev/null || \
                echo "WARNING: pods for $ns/$kind/$wname did not terminate within 180s" >&2
        done < "$scaled_file_all"
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
        while IFS= read -r entry; do
            ns=$(echo "$entry" | cut -d/ -f1)
            kind=$(echo "$entry" | cut -d/ -f2)
            wname=$(echo "$entry" | cut -d/ -f3)
            reps=$(echo "$entry" | cut -d/ -f4)
            echo "  Restoring $ns/$kind/$wname to $reps replicas..."
            kubectl scale "$kind" "$wname" -n "$ns" --replicas="$reps" 2>/dev/null || \
                echo "WARNING: failed to restore $ns/$kind/$wname" >&2
        done < "$scaled_file_all"
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
