#!/usr/bin/env sh
# Minimal NFSv4.2 server for the nfs-server Deployment. The nfsd kernel module
# is loaded by the nfs-modules init container; this process only mounts the
# kernel interface, starts the nfsd threads, and supervises rpc.mountd.
set -eu

NFSD=/usr/sbin/rpc.nfsd
MOUNTD=/usr/sbin/rpc.mountd
mountd_pid=

cleanup() {
    trap - EXIT TERM INT
    "$NFSD" 0 2>/dev/null || true
    if [ -n "$mountd_pid" ]; then
        kill "$mountd_pid" 2>/dev/null || true
        wait "$mountd_pid" 2>/dev/null || true
    fi
    umount -l /proc/fs/nfsd 2>/dev/null || true
    umount -l /var/lib/nfs/rpc_pipefs 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# The nfsd kernel module provides /proc/fs/nfsd; mount it so rpc.nfsd can
# configure the kernel. The check makes a container restart in the same mount
# namespace idempotent.
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

# rpc.nfsd configures the kernel threads and daemonizes. rpc.mountd stays in
# the foreground, so the container exits (and Kubernetes restarts it) if the
# user-space server dies.
"$NFSD" --tcp --no-udp --port 2049 --grace-time 10 --nfs-version 4.2 --no-nfs-version 3
"$MOUNTD" --foreground --port 32767 --nfs-version 4.2 --no-nfs-version 2 --no-nfs-version 3 &
mountd_pid=$!

wait "$mountd_pid"
