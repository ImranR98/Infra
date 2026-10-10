#!/bin/bash
# DESC: Watch the public-exposure hub for preboot-client handshakes and print
# one line per transition so logtfy can alert on it. Runs in the
# public-exposure-watch container (host network, NET_ADMIN); the first observed
# handshake only primes state, and a cooldown prevents re-alerts while the
# preboot session keeps re-handshaking.
set -euo pipefail

IF=pubexp-server0
PREBOOT_ALLOWED=10.99.0.4/32
COOLDOWN_SECS=1800

last=""
last_notify=0
while :; do
    pub="$(wg show "$IF" allowed-ips 2>/dev/null | awk -v c="$PREBOOT_ALLOWED" '$2 ~ c {print $1; exit}')"
    if [ -n "$pub" ]; then
        hs="$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1 == k {print $2}')"
        now="$(date +%s)"
        if [ -n "$hs" ] && [ "$hs" != "0" ] && [ "$hs" != "$last" ] && [ -n "$last" ] &&
            [ $((now - last_notify)) -ge "$COOLDOWN_SECS" ]; then
            echo "PREBOOT handshake: public-exposure-preboot-client-wg online"
            last_notify=$now
        fi
        last="$hs"
    fi
    sleep 10
done
