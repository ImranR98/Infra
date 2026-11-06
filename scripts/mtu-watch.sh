#!/bin/bash
# DESC: Keep a public-exposure WireGuard interface's MTU below the current
# path MTU. WireGuard has no PMTUD of its own, so probe the peer's outer IP
# with DF pings and set the inner MTU to path_mtu - overhead.
#
# Usage: mtu-watch.sh <interface> [peer-host]
#
# Tunables (environment):
#   MTU_WATCH_INTERVAL   seconds between probes (default 300)
#   MTU_WATCH_MIN        hard floor for the inner MTU (default 1200)
#   MTU_WATCH_MAX        ceiling for the inner MTU (default 1420)
#   MTU_WATCH_OVERHEAD   WireGuard + IP + UDP overhead (default 80)
set -euo pipefail

IF=${1:?interface is required}
PEER=${2:-}
INTERVAL=${MTU_WATCH_INTERVAL:-300}
MIN_MTU=${MTU_WATCH_MIN:-1200}
MAX_MTU=${MTU_WATCH_MAX:-1420}
OVERHEAD=${MTU_WATCH_OVERHEAD:-80}
PING_TIMEOUT=${MTU_WATCH_PING_TIMEOUT:-2}
CONF=${MTU_WATCH_CONF:-/etc/wireguard/${IF}.conf}

log() {
    printf '%s [mtu-watch:%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IF" "$*"
}

strip_port() {
    local value=$1
    value=${value%:*}
    value=${value#[}
    value=${value%]}
    printf '%s\n' "$value"
}

peer_host() {
    local endpoint
    if [[ -n "$PEER" ]]; then
        strip_port "$PEER"
        return 0
    fi
    endpoint=$(wg show "$IF" endpoints 2>/dev/null | awk 'NR == 1 { print $2 }')
    if [[ -z "$endpoint" || "$endpoint" == "(none)" ]]; then
        endpoint=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$CONF" 2>/dev/null || true)
    fi
    [[ -n "$endpoint" ]] || return 1
    strip_port "$endpoint"
}

is_ipv6() {
    [[ $1 == *:* ]]
}

ping_fits() {
    local host=$1 payload=$2
    if is_ipv6 "$host"; then
        ping -6 -n -c 1 -i 0.2 -W "$PING_TIMEOUT" -s "$payload" "$host" >/dev/null 2>&1
    else
        ping -4 -M "do" -n -c 1 -i 0.2 -W "$PING_TIMEOUT" -s "$payload" "$host" >/dev/null 2>&1
    fi
}

path_mtu() {
    local host=$1 header=28 max_payload=1472 lo=1000 hi mid best=0
    if is_ipv6 "$host"; then
        header=48
        max_payload=1452
    fi
    hi=$max_payload
    if ping_fits "$host" "$hi"; then
        printf '%s\n' $((hi + header))
        return 0
    fi
    while (( lo <= hi )); do
        mid=$(( (lo + hi) / 2 ))
        if ping_fits "$host" "$mid"; then
            best=$mid
            lo=$(( mid + 1 ))
        else
            hi=$(( mid - 1 ))
        fi
    done
    (( best > 0 )) || return 1
    printf '%s\n' $((best + header))
}

current_mtu() {
    ip link show dev "$IF" 2>/dev/null | awk '/ mtu / { for (i = 1; i < NF; i++) if ($i == "mtu") { print $(i + 1); exit } }'
}

last_peer=""
last_path=""
last_failure=""

while true; do
    peer=$(peer_host || true)
    if [[ -z "$peer" ]]; then
        if [[ "$last_failure" != "no-peer" ]]; then
            log "no peer endpoint yet; keeping MTU $(current_mtu)"
            last_failure=no-peer
        fi
    else
        if path=$(path_mtu "$peer"); then
            mtu=$(( path - OVERHEAD ))
            if (( mtu < MIN_MTU )); then
                log "path $path would need MTU $mtu; using floor $MIN_MTU"
                mtu=$MIN_MTU
            fi
            (( mtu > MAX_MTU )) && mtu=$MAX_MTU
            now=$(current_mtu)
            if [[ "$mtu" != "$now" ]]; then
                if ip link set dev "$IF" mtu "$mtu"; then
                    log "peer=$peer path=$path mtu $now -> $mtu"
                else
                    log "peer=$peer path=$path failed to set mtu $mtu"
                fi
            elif [[ "$peer" != "$last_peer" || "$path" != "$last_path" ]]; then
                log "peer=$peer path=$path mtu=$mtu"
            fi
            last_peer=$peer
            last_path=$path
            last_failure=""
        else
            if [[ "$last_failure" != "probe" ]]; then
                log "path probe to $peer failed; keeping MTU $(current_mtu)"
                last_failure=probe
            fi
        fi
    fi
    sleep "$INTERVAL"
done
