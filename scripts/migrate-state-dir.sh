#!/bin/bash
# DESC: One-time migration: move runtime state from the legacy in-repo
# current_target/ tree to ~/infra_state (outside the repo). Idempotent and
# dry-run capable. Run as the checkout owner on the machine being migrated.
#
# Usage:
#   migrate-state-dir.sh [--dry-run] [--no-symlink] [--k3s-agent-state]
#
#   --dry-run           print what would move; change nothing
#   --no-symlink        do not leave the temporary current_target -> infra_state
#                       compatibility symlink behind
#   --k3s-agent-state   also move the legacy ~/dscpln-agent/state tree to
#                       ~/infra_state/k3s_live_state/fl0w-agent (bigpc)
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"
set_my_uid

DRY_RUN=0
SYMLINK=1
K3S_AGENT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-symlink) SYMLINK=0 ;;
        --k3s-agent-state) K3S_AGENT=1 ;;
        -h | --help)
            sed -n '2,15p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

OLD="$INFRA_ROOT/current_target"
NEW="$INFRA_STATE_DIR"

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        printf '+'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    fi
}

ensure_dir() {
    local dir="$1"
    [ -d "$dir" ] && return 0
    run mkdir -p "$dir"
    run chmod 2775 "$dir"
}

move_path() {
    local src="$1" dst="$2" src_dev dst_dev
    [ -e "$src" ] || return 0
    if [ -e "$dst" ]; then
        echo "Error: destination already exists: $dst" >&2
        exit 1
    fi
    ensure_dir "$(dirname "$dst")"
    src_dev="$(stat -c %d "$(dirname "$src")")"
    probe="$(dirname "$dst")"
    while [ ! -d "$probe" ]; do
        probe="$(dirname "$probe")"
    done
    dst_dev="$(stat -c %d "$probe")"
    if [ "$src_dev" = "$dst_dev" ]; then
        run mv "$src" "$dst"
    else
        ensure_dir "$dst"
        run rsync -aHAX --numeric-ids "$src/" "$dst/"
        if [ "$DRY_RUN" = 0 ]; then
            if ! diff -qr "$src" "$dst" >/dev/null; then
                echo "Error: copy verification failed for $src -> $dst" >&2
                exit 1
            fi
            run rm -rf "$src"
        fi
    fi
}

[ -d "$INFRA_ROOT" ] || { echo "Error: INFRA_ROOT not found: $INFRA_ROOT" >&2; exit 1; }
case "$NEW/" in
    "$INFRA_ROOT/"*)
        echo "Error: INFRA_STATE_DIR must be outside INFRA_ROOT ($NEW)" >&2
        exit 1
        ;;
esac

echo "==> Runtime state migration"
echo "  repo:      $INFRA_ROOT"
echo "  state:     $NEW"
echo "  legacy:    $OLD"
[ "$DRY_RUN" = 1 ] && echo "  mode:      dry-run"

legacy_present=0
if [ -L "$OLD" ]; then
    target="$(readlink -f "$OLD")"
    if [ "$target" = "$(readlink -f "$NEW")" ]; then
        echo "  [OK] compatibility symlink already points at $NEW"
    else
        echo "Error: $OLD is a symlink to $target, expected $NEW" >&2
        exit 1
    fi
elif [ -d "$OLD" ]; then
    legacy_present=1
    for child in "$OLD"/*; do
        [ -e "$child" ] || continue
        name="$(basename "$child")"
        case "$name" in
            compose_live_state | k3s_live_state)
                move_path "$child" "$NEW/$name"
                ;;
            dscpln-agent)
                # The vps0 Compose FL0W agent used current_target/dscpln-agent/
                # state -> /state. Move its contents directly into the Compose
                # state tree so there is no nested state/ layer.
                if [ -d "$child/state" ]; then
                    move_path "$child/state" "$NEW/compose_live_state/fl0w-agent"
                    if [ -z "$(find "$child" -mindepth 1 -maxdepth 1 ! -name state -print -quit)" ]; then
                        run rmdir "$child"
                    else
                        echo "  [WARN] $child has entries besides state/; left in place" >&2
                    fi
                else
                    move_path "$child" "$NEW/$name"
                fi
                ;;
            *)
                echo "  [WARN] moving unrecognized state child: $name" >&2
                move_path "$child" "$NEW/$name"
                ;;
        esac
    done
    if [ "$DRY_RUN" = 0 ]; then
        if [ -z "$(find "$OLD" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            rmdir "$OLD"
        else
            echo "Error: $OLD is not empty after migration; inspect it before removing" >&2
            exit 1
        fi
    fi
fi

# The bigpc K3s FL0W agent state predates current_target and lives at
# ~/dscpln-agent/state. Move it into the K3s state tree when requested.
if [ "$K3S_AGENT" = 1 ]; then
    old_agent="$HOME/dscpln-agent"
    new_agent="$NEW/k3s_live_state/fl0w-agent"
    if [ -d "$old_agent/state" ]; then
        if [ -e "$new_agent" ]; then
            echo "Error: destination already exists: $new_agent" >&2
            exit 1
        fi
        if [ ! -e "$old_agent.pre-infra-state" ]; then
            run cp -a "$old_agent" "$old_agent.pre-infra-state"
        fi
        move_path "$old_agent/state" "$new_agent"
        if [ -z "$(find "$old_agent" -mindepth 1 -maxdepth 1 ! -name state -print -quit)" ]; then
            run rmdir "$old_agent"
        else
            echo "  [WARN] $old_agent has entries besides state/; left in place" >&2
        fi
    elif [ -d "$new_agent" ]; then
        echo "  [OK] K3s agent state already at $new_agent"
    else
        echo "  [SKIP] no legacy K3s agent state at $old_agent/state"
    fi
fi

ensure_dir "$NEW"
ensure_dir "$NEW/compose_live_state"
ensure_dir "$NEW/k3s_live_state"

if [ "$SYMLINK" = 1 ] && [ "$legacy_present" = 1 ] && [ ! -e "$OLD" ]; then
    run ln -s "$NEW" "$OLD"
    echo "  [OK] temporary compatibility symlink $OLD -> $NEW"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "==> Dry run complete; nothing changed"
    exit 0
fi

echo "==> State migration complete"
echo "  new root:  $NEW"
echo "  children:  $(find "$NEW" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
if [ -L "$OLD" ]; then
    echo "  symlink:   $OLD -> $NEW (remove after every consumer is verified)"
fi
