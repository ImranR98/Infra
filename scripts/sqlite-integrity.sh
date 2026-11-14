#!/bin/bash
# DESC: Check (default) or repair the SQLite databases under the app-data
# tree. Runs a throwaway pod on srv0 with the sqlite3 CLI, because the host and
# the app images do not ship it. The apps that own the databases MUST be
# stopped first: integrity checks and .recover need exclusive access.
#
# Usage:
#   sqlite-integrity.sh [check] [--yes]
#   sqlite-integrity.sh --repair [--yes]
#
# Repair keeps the original as <db>.corrupt-<timestamp> and drops the stale
# -wal/-shm sidecars. Rebuildable databases (the filebrowser search index, the
# *arr logs.db, the web-ui/ntfy caches) are deleted instead of recovered; the
# apps recreate them. This is a maintenance tool, not part of the deploy.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck source=scripts/common.sh
source "$INFRA_ROOT/scripts/common.sh"

MODE="check"
ASSUME_YES=0
case "${1:-check}" in
    check | --check) MODE="check" ;;
    --repair | repair) MODE="repair" ;;
    -h | --help) sed -n '2,18p' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
for arg in "$@"; do [ "$arg" = "--yes" ] && ASSUME_YES=1; done

APP_DATA_DIR="${K3S_STATE_DIR:-$INFRA_STATE_DIR/k3s_live_state}/app-data"
POD_NAME="sqlite-maintenance"
CONFIG_NAME="sqlite-maintenance"
NAMESPACE="base"
IMAGE="alpine:3.20.3"

[ -d "$APP_DATA_DIR" ] || { echo "app-data tree not found: $APP_DATA_DIR" >&2; exit 1; }
[ -n "$(kubectl get node srv0 -o name 2>/dev/null)" ] || { echo "srv0 not reachable via kubectl" >&2; exit 1; }

if [ "$ASSUME_YES" != 1 ]; then
    echo "This must run with the SQLite apps scaled to 0."
    printf 'Mode: %s. Continue? [y/N] ' "$MODE"
    read -r answer
    case "$answer" in y | Y | yes | YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# Databases that are safe to throw away; the owning app rebuilds them.
DROP_PATHS="
apps/filebrowser-pvc/cache/sql/index_all.db
apps/prowlarr-config-pvc/logs.db
apps/radarr-config-pvc/logs.db
apps/sonarr-config-pvc/logs.db
base/crowdsec-web-ui-pvc/cache.db
base/ntfy-pvc/cache.db
"

# Live databases. FresRSS's user DB is discovered by find because the user
# directory is not world-readable on the host.
DB_PATHS="
apps/filebrowser-pvc/database.sqlite
apps/fmd-pvc/fmd.sqlite
apps/freshrss-data-pvc/users/admin/db.sqlite
apps/frigate-config-pvc/frigate.db
apps/homeassistant-config-pvc/home-assistant_v2.db
apps/homeassistant-config-pvc/zigbee.db
apps/jellyfin-config-pvc/data/jellyfin.db
apps/lifetagger-data-pvc/lifetagger.db
apps/navidrome-data-pvc/navidrome.db
apps/open-webui-data-pvc/webui.db
apps/open-webui-data-pvc/vector_db/chroma.sqlite3
apps/opencode-home-pvc/.local/share/opencode/opencode.db
apps/opodsync-pvc/data.sqlite
apps/plik-state-pvc/plik.db
apps/prowlarr-config-pvc/prowlarr.db
apps/radarr-config-pvc/radarr.db
apps/seerr-config/db/db.sqlite3
apps/sonarr-config-pvc/sonarr.db
base/crowdsec-pvc/crowdsec/crowdsec.db
base/crowdsec-web-ui-pvc/state.db
base/grafana/grafana.db
base/ntfy-pvc/user.db
"

RUN_SCRIPT=$(cat <<'EOS'
#!/bin/sh
set -u
: "${REPAIR:=0}"
ok=0
bad=0
# FreshRSS keeps its SQLite DB under the user directory; discover it because
# the directory is not world-readable on the host.
for f in $(cd /data 2>/dev/null && find apps/freshrss-data-pvc/users -maxdepth 2 -type f \( -name '*.sqlite' -o -name '*.db' \) 2>/dev/null); do
    case " $DB_PATHS " in *" $f "*) ;; *) DB_PATHS="$DB_PATHS $f" ;; esac
done
for rel in $DROP_PATHS; do
    db="/data/$rel"
    [ -f "$db" ] || continue
    if q=$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1) && [ "$q" = "ok" ]; then
        echo "OK        $rel"
        ok=$((ok + 1))
    else
        echo "CORRUPT   $rel (rebuildable)"
        bad=$((bad + 1))
        if [ "$REPAIR" = 1 ]; then
            rm -f "$db" "$db-wal" "$db-shm"
            echo "  dropped: $rel"
        fi
    fi
done
for rel in $DB_PATHS; do
    db="/data/$rel"
    [ -f "$db" ] || continue
    if q=$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1) && [ "$q" = "ok" ]; then
        echo "OK        $rel"
        ok=$((ok + 1))
        continue
    fi
    echo "CORRUPT   $rel"
    bad=$((bad + 1))
    if [ "$REPAIR" != 1 ]; then
        continue
    fi
    out="$db.recovered"
    rm -f "$out" "$db-wal" "$db-shm"
    if ! sqlite3 "$db" ".recover" 2>/dev/null | sqlite3 "$out" 2>/dev/null; then
        echo "  RECOVER FAILED: $rel (original kept)"
        rm -f "$out"
        continue
    fi
    if q2=$(sqlite3 "$out" 'PRAGMA integrity_check;' 2>&1) && [ "$q2" = "ok" ]; then
        mv "$db" "$db.corrupt-$(date -u +%Y%m%d%H%M%S)"
        mv "$out" "$db"
        rm -f "$db-wal" "$db-shm"
        echo "  recovered: $rel (original kept as .corrupt-*)"
    else
        echo "  RECOVER INCOMPLETE: $rel (kept $out)"
    fi
done
echo "SUMMARY ok=$ok corrupt=$bad"
EOS
)

echo "==> app-data: $APP_DATA_DIR"
kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found --wait=true >/dev/null
kubectl -n "$NAMESPACE" delete configmap "$CONFIG_NAME" --ignore-not-found >/dev/null
kubectl -n "$NAMESPACE" create configmap "$CONFIG_NAME" --from-literal=run.sh="$RUN_SCRIPT" >/dev/null

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
spec:
  restartPolicy: Never
  nodeSelector:
    infra.local/hostpath-main: "true"
  containers:
    - name: sqlite
      image: $IMAGE
      command: ["/bin/sh", "-c"]
      args:
        - apk add --no-cache sqlite >/dev/null && /bin/sh /scripts/run.sh
      env:
        - name: REPAIR
          value: "$([ "$MODE" = repair ] && echo 1 || echo 0)"
        - name: DROP_PATHS
          value: "$(echo "$DROP_PATHS" | tr '\n' ' ')"
        - name: DB_PATHS
          value: "$(echo "$DB_PATHS" | tr '\n' ' ')"
      volumeMounts:
        - name: data
          mountPath: /data
        - name: scripts
          mountPath: /scripts
  volumes:
    - name: data
      hostPath:
        path: $APP_DATA_DIR
        type: Directory
    - name: scripts
      configMap:
        name: $CONFIG_NAME
EOF

echo "==> waiting for $POD_NAME"
for _ in $(seq 1 300); do
    phase=$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 2
done

kubectl -n "$NAMESPACE" logs "$POD_NAME" || true
phase=$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found --wait=false >/dev/null
kubectl -n "$NAMESPACE" delete configmap "$CONFIG_NAME" --ignore-not-found >/dev/null
[ "$phase" = "Succeeded" ] || { echo "pod finished as: ${phase:-unknown}" >&2; exit 1; }
