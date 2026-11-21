#!/bin/bash
# state-restore.sh — manual restore for the D4TA state snapshots.
#
# Snapshots live under state_backups/snapshots/<UTC timestamp>/ and contain
# app-data, db-dumps, compose, and a manifest. Run this on srv0 with the
# state_backups tree present (it is Syncthing-replicated).
#
# Usage:
#   state-restore.sh list
#   state-restore.sh restore [snapshot] [--live] [--yes]
#   state-restore.sh db <ns/pvc> [snapshot]
#   state-restore.sh compose <srv0|vps0> [snapshot] [--live] [--yes]
#
# `restore` and `compose` default to a staging directory. `--live` replaces
# the live app-data or Compose state; `restore --live` requires root and the
# apps should be stopped first. `db` only stages the dump and prints the
# Postgres/SQLite restore command.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

STATE_BACKUP_DIR="${STATE_BACKUP_DIR:-$INFRA_ROOT/state_backups}"
SNAP_ROOT="$STATE_BACKUP_DIR/snapshots"
LATEST="$STATE_BACKUP_DIR/latest"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
VPS0_HOST="${VPS0_HOST:-$(config_env srv0 PUBLIC_EXPOSURE_HOST 2>/dev/null || true)}"
VPS0_USER="${VPS0_USER:-root}"
VPS0_STATE_DIR="${VPS0_STATE_DIR:-/root/infra_state/compose_live_state}"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# //'
    exit "${1:-1}"
}

require_rsync() {
    command -v rsync >/dev/null 2>&1 || {
        echo "rsync is not installed on this host" >&2
        exit 1
    }
}

confirm_live() {
    local target="$1" yes="${2:-false}"
    [ "$yes" = true ] && return 0
    echo "This will overwrite live data for: $target"
    read -r -p "Type the target name to continue: " answer
    [ "$answer" = "$target" ] || { echo "Aborted."; exit 1; }
}

snapshot_arg() {
    local arg="${1:-latest}" target
    if [ "$arg" = latest ] || [ -z "$arg" ]; then
        target="$(readlink -f "$LATEST" 2>/dev/null || true)"
    else
        target="$SNAP_ROOT/$arg"
    fi
    [ -n "$target" ] && [ -d "$target" ] || {
        echo "Snapshot not found: ${arg:-latest}" >&2
        exit 1
    }
    printf '%s' "$target"
}

list_snapshots() {
    [ -d "$SNAP_ROOT" ] || return 0
    find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r
}

restore_snapshot() {
    local snapshot="$1" live="$2" yes="$3" snap stage
    snap="$(snapshot_arg "$snapshot")"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/state-restore.XXXXXX")"
    echo "Staging $snap to $stage" >&2
    rsync -a "$snap/" "$stage/"
    echo "Staged snapshot: $stage"
    echo "App data: $stage/app-data"
    echo "DB dumps: $stage/db-dumps"
    echo "Compose: $stage/compose"
    if [ "$live" = true ]; then
        confirm_live "app-data" "$yes"
        [ "$(id -u)" -eq 0 ] || { echo "--live requires root (run with sudo)" >&2; exit 1; }
        rsync -a --delete "$stage/app-data/" "$K3S_STATE_DIR/app-data/"
        echo "Restored app-data to $K3S_STATE_DIR/app-data"
        echo "Restore DBs with: $0 db $snapshot <ns/pvc>"
    fi
}

restore_db() {
    local target="$1" snapshot="$2" snap stage
    [ -n "$target" ] || usage
    snap="$(snapshot_arg "$snapshot")"
    [ -d "$snap/db-dumps/$target" ] || {
        echo "No DB dump for $target in $(basename "$snap")" >&2
        exit 1
    }
    stage="$(mktemp -d "${TMPDIR:-/tmp}/state-restore-db.XXXXXX")"
    rsync -a "$snap/db-dumps/$target/" "$stage/"
    echo "Staged DB dump: $stage"
    if [ -f "$stage/postgres.dump" ]; then
        echo "Postgres: pg_restore -U <user> -d <db> $stage/postgres.dump"
    else
        find "$stage" -type f -printf 'SQLite: %p\n'
        echo "Stop the owning app before copying a SQLite file into place."
    fi
}

restore_compose() {
    local target="$1" snapshot="$2" live="$3" yes="$4" snap stage
    [ -n "$target" ] || usage
    snap="$(snapshot_arg "$snapshot")"
    [ -d "$snap/compose/$target" ] || {
        echo "No compose state for $target in $(basename "$snap")" >&2
        exit 1
    }
    stage="$(mktemp -d "${TMPDIR:-/tmp}/state-restore-compose.XXXXXX")"
    rsync -a "$snap/compose/$target/" "$stage/"
    echo "Staged compose state: $stage"
    [ "$live" = true ] || return 0
    confirm_live "$target" "$yes"
    case "$target" in
        srv0)
            [ "$(id -u)" -eq 0 ] || { echo "--live srv0 requires root" >&2; exit 1; }
            rsync -a --delete "$stage/" "$COMPOSE_STATE_DIR/"
            echo "Restored srv0 compose state to $COMPOSE_STATE_DIR"
            ;;
        vps0)
            [ -n "$VPS0_HOST" ] || {
                echo "Set VPS0_HOST or PUBLIC_EXPOSURE_HOST in config/srv0/compose.env" >&2
                exit 1
            }
            [ -f "$SSH_KEY_FILE" ] || {
                echo "SSH key not found: $SSH_KEY_FILE (set SSH_KEY_FILE)" >&2
                exit 1
            }
            rsync -a --delete -e "ssh -i '$SSH_KEY_FILE' -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$KNOWN_HOSTS'" \
                "$stage/" "$VPS0_USER@$VPS0_HOST:$VPS0_STATE_DIR/"
            echo "Restored vps0 compose state to $VPS0_HOST:$VPS0_STATE_DIR"
            ;;
        *) usage ;;
    esac
}

main() {
    local action="${1:-}" target="" snapshot="latest" live=false yes=false
    shift || true

    case "$action" in
        list|snapshots)
            list_snapshots
            return
            ;;
        restore)
            if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                snapshot="$1"
                shift
            fi
            ;;
        db)
            target="${1:-}"
            [ -n "$target" ] || usage
            shift || true
            if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                snapshot="$1"
                shift
            fi
            ;;
        compose)
            target="${1:-}"
            [ -n "$target" ] || usage
            shift || true
            if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                snapshot="$1"
                shift
            fi
            ;;
        -h|--help|help|'')
            usage 0
            ;;
        *)
            usage
            ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --live) live=true ;;
            --yes) yes=true ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done

    require_rsync
    case "$action" in
        restore) restore_snapshot "$snapshot" "$live" "$yes" ;;
        db) restore_db "$target" "$snapshot" ;;
        compose) restore_compose "$target" "$snapshot" "$live" "$yes" ;;
    esac
}

main "$@"
