#!/bin/bash
# restic-restore.sh — manual restore for the D$CPLN State Backups repository.
#
# The app is backup-only; this script is the recovery path and works without
# the app (or on a fresh cluster). Run it on srv0 with the repo present.
#
# Usage:
#   restic-restore.sh list
#   restic-restore.sh pvc <pvc-name> [snapshot] [--live] [--yes]
#   restic-restore.sh compose <srv0|vps0> [snapshot] [--live] [--yes]
#
# `pvc` and `compose` default to restoring into a staging directory. `--live`
# additionally replaces the live host path; for a PVC it scales the referencing
# Deployments/StatefulSets down and back up, so it must run as root (or with
# write access to the NFS app-data tree).
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

STATE_BACKUP_DIR="${STATE_BACKUP_DIR:-$INFRA_ROOT/state_backups}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$STATE_BACKUP_DIR/restic}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-dscpln-state-backups-default-2026}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$HOME/.cache/restic}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$INFRA_ROOT/config/state-backup-vps0/id_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
VPS0_HOST="${VPS0_HOST:-vps0.imranr.dev}"
VPS0_USER="${VPS0_USER:-root}"

export RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_CACHE_DIR

usage() {
    sed -n '2,18p' "$0" | sed 's/^# //'
    exit "${1:-1}"
}

require_restic() {
    command -v restic >/dev/null 2>&1 || {
        echo "restic is not installed on this host" >&2
        exit 1
    }
}

snapshot_arg() {
    local snap="${1:-latest}"
    printf '%s' "$snap"
}

restore_to_staging() {
    local snapshot="$1" source_path="$2"
    local staging
    staging=$(mktemp -d "${TMPDIR:-/tmp}/restic-restore.XXXXXX")
    echo "Restoring $source_path from snapshot $snapshot to $staging"
    restic restore "$snapshot" --target "$staging" --include "$source_path" --verify
    printf '%s\n' "$staging"
}

scale_down() {
    local ns="$1" pvc="$2" scaled_file="$3"
    local workloads kind wname reps
    workloads=$(kubectl get deploy,sts -n "$ns" -o json 2>/dev/null | \
        jq -r --arg pvc "$pvc" \
        '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | "\(.kind)/\(.metadata.name)"')
    for w in $workloads; do
        kind="${w%%/*}"
        wname="${w##*/}"
        reps=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
        echo "$ns/$kind/$wname/$reps" >> "$scaled_file"
        [ "$reps" = "0" ] || kubectl scale "$kind" "$wname" -n "$ns" --replicas=0
    done
}

wait_for_pods() {
    local scaled_file="$1"
    while IFS= read -r entry; do
        local ns kind wname selector
        ns=$(cut -d/ -f1 <<<"$entry")
        kind=$(cut -d/ -f2 <<<"$entry")
        wname=$(cut -d/ -f3 <<<"$entry")
        selector=$(kubectl get "$kind" "$wname" -n "$ns" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | \
            jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        [ -n "$selector" ] || continue
        kubectl wait --for=delete pod -n "$ns" --selector="$selector" --timeout=180s 2>/dev/null || \
            echo "WARNING: pods for $ns/$kind/$wname did not terminate" >&2
    done < "$scaled_file"
}

scale_up() {
    local scaled_file="$1"
    while IFS= read -r entry; do
        local ns kind wname reps
        ns=$(cut -d/ -f1 <<<"$entry")
        kind=$(cut -d/ -f2 <<<"$entry")
        wname=$(cut -d/ -f3 <<<"$entry")
        reps=$(cut -d/ -f4 <<<"$entry")
        kubectl scale "$kind" "$wname" -n "$ns" --replicas="$reps" 2>/dev/null || \
            echo "WARNING: failed to restore $ns/$kind/$wname to $reps" >&2
    done < "$scaled_file"
}

confirm_live() {
    local target="$1" yes="${2:-false}"
    [ "$yes" = true ] && return 0
    echo "This will overwrite live data for: $target"
    read -r -p "Type the target name to continue: " answer
    [ "$answer" = "$target" ] || { echo "Aborted."; exit 1; }
}

restore_pvc() {
    local pvc="$1" snapshot="$2" live="$3" yes="$4"
    local ns dest staging restored scaled_file
    ns=$(kubectl get pvc -A -o json | jq -r --arg pvc "$pvc" \
        '.items[] | select(.metadata.name == $pvc) | .metadata.namespace' | head -n1)
    [ -n "$ns" ] || { echo "PVC not found: $pvc" >&2; exit 1; }
    dest="$INFRA_ROOT/current_target/k3s_live_state/nfs-apps/$ns/$pvc"
    [ -d "$dest" ] || { echo "Destination not found: $dest" >&2; exit 1; }

    staging=$(restore_to_staging "$(snapshot_arg "$snapshot")" "$dest")
    restored="$staging$dest"
    [ -d "$restored" ] || { echo "Restored path not found: $restored" >&2; exit 1; }
    echo "Staged restore: $restored"

    [ "$live" = true ] || { echo "Live path left untouched. Use --live to replace $dest."; exit 0; }
    confirm_live "$pvc" "$yes"
    [ "$(id -u)" -eq 0 ] || { echo "--live requires root (run with sudo)" >&2; exit 1; }

    scaled_file=$(mktemp)
    trap 'scale_up "$scaled_file"; rm -f "$scaled_file"; rm -rf "$staging"' EXIT
    scale_down "$ns" "$pvc" "$scaled_file"
    wait_for_pods "$scaled_file"
    rsync -a --delete "$restored/" "$dest/"
    echo "Restored $pvc to $dest"
}

restore_compose() {
    local target="$1" snapshot="$2" live="$3" yes="$4"
    local source_path dest staging restored
    case "$target" in
        srv0)
            source_path="$INFRA_ROOT/current_target/compose_live_state"
            dest="$source_path"
            ;;
        vps0)
            # Current snapshots use the stable in-pod staging path. Older
            # snapshots used a random staging directory; discover either.
            source_path="${VPS0_SNAPSHOT_PATH:-}"
            if [ -z "$source_path" ]; then
                source_path=$(restic ls "$(snapshot_arg "$snapshot")" 2>/dev/null | awk '/\/vps0$/ { print; exit }')
            fi
            [ -n "$source_path" ] || { echo "No /vps0 path found in snapshot $snapshot" >&2; exit 1; }
            dest="/root/Infra/current_target/compose_live_state"
            ;;
        *)
            echo "compose target must be srv0 or vps0" >&2
            exit 1
            ;;
    esac

    staging=$(restore_to_staging "$(snapshot_arg "$snapshot")" "$source_path")
    restored="$staging$source_path"
    [ -d "$restored" ] || { echo "Restored path not found: $restored" >&2; exit 1; }
    echo "Staged restore: $restored"

    [ "$live" = true ] || { echo "Live path left untouched. Use --live to apply."; exit 0; }
    confirm_live "$target" "$yes"

    if [ "$target" = srv0 ]; then
        [ "$(id -u)" -eq 0 ] || { echo "--live srv0 requires root (run with sudo)" >&2; exit 1; }
        rsync -a --delete "$restored/" "$dest/"
        echo "Restored srv0 compose state to $dest"
    else
        [ -f "$SSH_KEY_FILE" ] || { echo "SSH key not found: $SSH_KEY_FILE" >&2; exit 1; }
        rsync -a --delete -e "ssh -i '$SSH_KEY_FILE' -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$KNOWN_HOSTS'" \
            "$restored/" "$VPS0_USER@$VPS0_HOST:$dest/"
        echo "Restored vps0 compose state to $dest"
    fi
}

main() {
    local action="${1:-}"
    local target="" snapshot="latest" live=false yes=false
    shift || true

    case "$action" in
        list|snapshots)
            require_restic
            restic snapshots
            return
            ;;
        pvc|compose)
            target="${1:-}"
            [ -n "$target" ] || usage
            shift || true
            ;;
        -h|--help|help|'')
            usage 0
            ;;
        *)
            usage
            ;;
    esac

    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        snapshot="$1"
        shift
    fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --live) live=true ;;
            --yes) yes=true ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done

    require_restic
    if [ "$action" = pvc ]; then
        restore_pvc "$target" "$snapshot" "$live" "$yes"
    else
        restore_compose "$target" "$snapshot" "$live" "$yes"
    fi
}

main "$@"
