#!/bin/bash
# DESC: Publish an ntfy notification when an AmneziaWG peer transitions from
# offline to online. Runs as a sidecar in the remote-access-amneziawg pod;
# reads the userspace UAPI socket shared via /var/run/amneziawg and the server
# config on the PVC for peer names. State is primed on start, so pod restarts
# while a client is connected do not re-notify.
set -euo pipefail

WG_IF=ra-amneziawg0
WG_CONF=/wg/ra-amneziawg0.conf
ONLINE_SECS=240
COOLDOWN_SECS=600

: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

peer_name() {
    awk -v key="$1" '
        /^# / { name = substr($0, 3) }
        /^PublicKey[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            if ($0 == key) { print (name == "" ? "unknown" : name); exit }
        }' "$WG_CONF"
}

notify() {
    local name="$1"
    wget -q -O /dev/null \
        --header="Authorization: Bearer $NTFY_TOKEN" \
        --header="Title: AmneziaWG on srv0" \
        --post-data="$name connected." \
        "$NTFY_URL/$NTFY_TOPIC" ||
        echo "notify: publish failed for $name" >&2
    echo "notify: $name connected."
}

declare -A online last_notify
while :; do
    now=$(date +%s)
    if ! dump="$(awg show "$WG_IF" dump 2>/dev/null)"; then
        sleep 30
        continue
    fi
    while read -r pub _psk _ep _allowed hs _rx _tx _ka; do
        [ -n "$pub" ] || continue
        is_online=0
        [ "$((now - hs))" -lt "$ONLINE_SECS" ] && is_online=1
        case "${online[$pub]:-}" in
            "")
                online[$pub]=$is_online
                ;;
            0)
                if [ "$is_online" = 1 ] && [ "$((now - ${last_notify[$pub]:-0}))" -ge "$COOLDOWN_SECS" ]; then
                    notify "$(peer_name "$pub")"
                    last_notify[$pub]=$now
                fi
                online[$pub]=$is_online
                ;;
            *)
                online[$pub]=$is_online
                ;;
        esac
    done < <(tail -n +2 <<<"$dump")
    sleep 30
done
