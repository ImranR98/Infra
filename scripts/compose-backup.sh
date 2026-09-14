#!/bin/bash
# DESC: Back up the compose runtime state of one target (tar via an Alpine
# container — skips FIFOs/sockets, so no mknod errors; tar exit 1 from files
# changing mid-read is expected for live state and accepted), pruning to
# BACKUP_RETENTION archives (default 1); a failed run removes its partial
# archive. Local mode tars this checkout's current_target/compose_live_state
# and must run ON the target; it asserts hostname == target. Docker is run via
# sudo when this user can't reach the daemon (sudo prompts; SUDO_PASSWORD feeds
# sudo -S for non-interactive runs). With
# -e backup_remote=user@host:path the tar instead streams back over SSH from
# the remote checkout (the remote runs docker directly — this script never
# runs there), so it can run from any machine; remote sudo uses the supplied
# password via -S, or passwordless -n, since a prompt can't share the tar
# stream. A remote hostname that differs from <target> only warns.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target> [-e backup_remote=user@host:path]"
    echo
    echo "  <target>                  tars \$INFRA_ROOT/current_target/compose_live_state"
    echo "                            into compose_state_backups/<target>-backup-<ts>.tar"
    echo "                            (run ON the target)"
    echo "  -e backup_remote=h:p      instead stream the tar over SSH from host h"
    echo "                            (remote repo checkout at path p) into this"
    echo "                            machine's compose_state_backups/, named after"
    echo "                            <target>; runs from any machine and only warns"
    echo "                            when h's hostname differs from <target>"
    echo
    echo "Set SUDO_PASSWORD to feed sudo -S without an interactive prompt; it is"
    echo "not inherited by child processes."
    exit 1
}

backup_remote=""
target_arg=""
sudo_password="${SUDO_PASSWORD:-}"
unset SUDO_PASSWORD  # don't leak it into child (docker/ssh) environments
have_remote=false
while [ $# -gt 0 ]; do
    case "$1" in
        -e)
            [ $# -ge 2 ] || usage
            backup_remote="$2"
            have_remote=true
            shift 2
            ;;
        -e*)
            backup_remote="${1#-e}"
            have_remote=true
            shift
            ;;
        -h | --help)
            usage
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
        *)
            [ -z "$target_arg" ] || usage
            target_arg="$1"
            shift
            ;;
    esac
done
if [ "$have_remote" = true ]; then
    backup_remote="${backup_remote#=}"
    backup_remote="${backup_remote#backup_remote=}"
    if [[ "$backup_remote" != *:* ]]; then
        echo "Error: -e backup_remote needs user@host:path" >&2
        usage
    fi
fi
[ -n "$target_arg" ] || usage

if [ -n "$backup_remote" ]; then
    require_target "$target_arg"
else
    require_target_host "$target_arg"
fi

retention="${BACKUP_RETENTION:-1}"
backup_dir="$INFRA_ROOT/compose_state_backups"
mkdir -p "$backup_dir"
umask 0077

# apk failure exits 2 so it can't be mistaken for tar's tolerated exit 1.
# shellcheck disable=SC2016  # $?/$rc expand in the container's sh, not locally
tar_cmd='apk add --no-cache tar >/dev/null || exit 2; find /backup/state \( -type f -o -type d -o -type l \) -print0 | tar cf - --null -T - --sparse --ignore-failed-read --warning=no-file-changed --warning=no-file-removed; rc=$?; if [ "$rc" -gt 1 ]; then exit "$rc"; fi; [ "$rc" -eq 1 ] && echo "Note: some live files changed during the backup; the archive was still written" >&2; exit 0'

if [ -n "$backup_remote" ]; then
    host="${backup_remote%%:*}"
    path="${backup_remote#*:}"
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    remote_hostname="$(ssh -T "$host" hostname)" || remote_hostname=""
    if [ -z "$remote_hostname" ]; then
        echo "Error: cannot SSH to '$host'." >&2
        exit 1
    fi
    if [ "$remote_hostname" != "$TARGET" ]; then
        echo "Warning: remote host '$host' is named '$remote_hostname', not target '$TARGET'; saving as $(basename "$out")" >&2
    fi
    # The tar stream leaves no tty for a sudo prompt: feed the supplied password
    # to sudo -S over stdin, else fall back to passwordless sudo -n.
    remote_docker="docker"
    remote_sudo_password=false
    if ! ssh -T "$host" "docker info >/dev/null 2>&1"; then
        if [ -n "$sudo_password" ]; then
            if printf '%s\n' "$sudo_password" | ssh -T "$host" "sudo -S -p '' docker info >/dev/null 2>&1"; then
                remote_docker="sudo -S -p '' docker"
                remote_sudo_password=true
                echo "Remote docker needs elevated privileges; using 'sudo -S' with the supplied password on $host" >&2
            else
                echo "Error: docker on '$host' is not usable via sudo with the supplied password." >&2
                exit 1
            fi
        elif ssh -T "$host" "sudo -n docker info >/dev/null 2>&1"; then
            remote_docker="sudo -n docker"
            echo "Remote docker needs elevated privileges; using 'sudo -n' on $host" >&2
        else
            echo "Error: docker on '$host' is not usable by the SSH user (needs root, the docker group, passwordless sudo, or SUDO_PASSWORD)." >&2
            exit 1
        fi
    fi
    echo "Backing up compose state from $host (remote checkout at $path)..."
    remote_tar="cd '$path' && test -d current_target/compose_live_state && $remote_docker run --rm --log-driver none -v \$PWD/current_target/compose_live_state:/backup/state:ro alpine sh -c '$tar_cmd'"
    backup_rc=0
    if [ "$remote_sudo_password" = true ]; then
        printf '%s\n' "$sudo_password" | ssh -T "$host" "$remote_tar" >"$out" || backup_rc=$?
    else
        ssh -T "$host" "$remote_tar" >"$out" || backup_rc=$?
    fi
    if [ "$backup_rc" -ne 0 ]; then
        echo "Error: remote backup failed; removed partial archive $out" >&2
        rm -f "$out"
        exit 1
    fi
else
    state_dir="$INFRA_ROOT/current_target/compose_live_state"
    if [ ! -d "$state_dir" ]; then
        echo "Error: state directory not found: $state_dir" >&2
        exit 1
    fi
    docker_cmd=(docker)
    need_sudo=false
    docker_rc=0
    docker_err="$(docker info 2>&1 >/dev/null)" || docker_rc=$?
    if [ "$docker_rc" -ne 0 ]; then
        if [[ "$docker_err" == *[Pp]ermission\ denied* ]]; then
            need_sudo=true
            if [ -n "$sudo_password" ]; then
                if ! printf '%s\n' "$sudo_password" | "$(get_sudo_cmd)" -S -p '' docker info >/dev/null 2>&1; then
                    echo "Error: docker is not usable via $(get_sudo_cmd) with the supplied password." >&2
                    exit 1
                fi
                docker_cmd=("$(get_sudo_cmd)" -S -p '' docker)
                echo "Docker needs elevated privileges; using 'sudo -S' with the supplied password" >&2
            else
                docker_cmd=("$(get_sudo_cmd)" docker)
                echo "Docker needs elevated privileges; using ${docker_cmd[*]}" >&2
            fi
        else
            echo "Error: docker is not usable: ${docker_err:-exit $docker_rc}" >&2
            exit 1
        fi
    fi
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    echo "Backing up compose state at $state_dir..."
    tar_run=("${docker_cmd[@]}" run --rm --log-driver none -v "$state_dir":/backup/state:ro alpine sh -c "$tar_cmd")
    backup_rc=0
    if [ "$need_sudo" = true ] && [ -n "$sudo_password" ]; then
        printf '%s\n' "$sudo_password" | "${tar_run[@]}" >"$out" || backup_rc=$?
    else
        "${tar_run[@]}" >"$out" || backup_rc=$?
    fi
    if [ "$backup_rc" -ne 0 ]; then
        echo "Error: backup failed; removed partial archive $out" >&2
        rm -f "$out"
        exit 1
    fi
fi

echo "Backup created: $out"
ls -1t "$backup_dir"/"${TARGET}"-backup-*.tar 2>/dev/null |
    tail -n +$((retention + 1)) | xargs -r rm -f
