#!/bin/bash
# DESC: Deploy and verify the srv0 K3s charts. Runs validate, upgrades srv0-base
# then srv0-apps, waits for the helm-controller install jobs and workload
# rollouts, and checks pod readiness, HelmChart failures, restart counts, and
# the API server readiness. Workloads scheduled only on NotReady nodes (for
# example bigpc when it is powered off) are reported as warnings and skipped.
#
# Usage: deploy.sh [srv0] [--dry-run] [--timeout S]
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"

target="srv0"
dry_run=0
timeout=600
while [ $# -gt 0 ]; do
    case "$1" in
        srv0) target="srv0" ;;
        --dry-run) dry_run=1 ;;
        --timeout)
            if [ $# -lt 2 ]; then
                echo "Error: --timeout requires seconds" >&2
                exit 1
            fi
            timeout="$2"
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [srv0] [--dry-run] [--timeout S]" >&2
            exit 0
            ;;
        *)
            echo "Usage: $(basename "$0") [srv0] [--dry-run] [--timeout S]" >&2
            exit 1
            ;;
    esac
    shift
done
if [ "$target" != "srv0" ]; then
    echo "Error: deploy.sh currently supports srv0 only; deploy other targets with compose/SSH." >&2
    exit 1
fi
require_target_host "$target"

for cmd in helm kubectl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: $cmd is required." >&2
        exit 1
    }
done

base_args=(
    upgrade --install srv0-base "$INFRA_ROOT/targets/srv0/k3s-base"
    -n base --create-namespace
    -f "$INFRA_ROOT/targets/srv0/k3s-base/values.yaml"
    -f "$INFRA_ROOT/config/srv0/values.yaml"
)
apps_args=(
    upgrade --install srv0-apps "$INFRA_ROOT/targets/srv0/k3s-apps"
    -n apps --create-namespace
    -f "$INFRA_ROOT/targets/srv0/k3s-apps/values.yaml"
    -f "$INFRA_ROOT/config/srv0/values.yaml"
)

echo "==> Validate srv0"
bash "$INFRA_ROOT/scripts/validate.sh" srv0

if [ "$dry_run" = 1 ]; then
    printf 'helm'; printf ' %q' "${base_args[@]}"; printf '\n'
    printf 'helm'; printf ' %q' "${apps_args[@]}"; printf '\n'
    echo "deploy: dry run OK (srv0)"
    exit 0
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    echo "Error: cannot reach the cluster. Run scripts/kubeconfig-unlock.sh in another terminal (the admin kubeconfig is root-only)." >&2
    exit 1
fi

not_ready_nodes="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}')"

wait_for_helmchart_jobs() {
    local ns="$1"
    local quiet=0 active deadline=$((SECONDS + timeout))
    if ! kubectl -n "$ns" get helmcharts -o name 2>/dev/null | grep -q .; then
        return 0
    fi
    # helm-controller creates the install Job a few seconds after the CR update.
    sleep 5
    while [ "$SECONDS" -lt "$deadline" ]; do
        active="$(kubectl -n "$ns" get jobs -l 'helmcharts.helm.cattle.io/chart' -o json 2>/dev/null |
            jq -r '.items[] | select((.status.active // 0) > 0) | .metadata.name' || true)"
        if [ -z "$active" ]; then
            quiet=$((quiet + 1))
            [ "$quiet" -ge 3 ] && return 0
        else
            quiet=0
        fi
        sleep 5
    done
    echo "Error: HelmChart install jobs in $ns did not settle within ${timeout}s" >&2
    return 1
}

workload_only_on_not_ready_nodes() {
    local ns="$1" kind="$2" name="$3" selector nodes node
    selector="$(kubectl -n "$ns" get "$kind" "$name" -o json |
        jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")')"
    [ -n "$selector" ] || return 1
    nodes="$(kubectl -n "$ns" get pods -l "$selector" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sed '/^$/d')"
    [ -n "$nodes" ] || return 1
    while IFS= read -r node; do
        printf '%s\n' "$not_ready_nodes" | grep -qx "$node" || return 1
    done <<<"$nodes"
    return 0
}

echo "==> helm upgrade srv0-base"
helm "${base_args[@]}"
wait_for_helmchart_jobs base

echo "==> helm upgrade srv0-apps"
helm "${apps_args[@]}"
wait_for_helmchart_jobs apps

echo "==> Wait for workload rollouts"
for ns in base apps; do
    for kind in deployment statefulset daemonset; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if ! kubectl -n "$ns" rollout status "$kind/$name" --timeout=120s; then
                if workload_only_on_not_ready_nodes "$ns" "$kind" "$name"; then
                    echo "warning: $kind/$name is only scheduled on NotReady node(s); skipping" >&2
                else
                    echo "Error: $kind/$name did not roll out" >&2
                    exit 1
                fi
            fi
        done < <(kubectl -n "$ns" get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    done
done

check_pods() {
    local ns="$1" out="" warnings errors
    local i
    for ((i = 0; i < 12; i++)); do
        out="$(kubectl -n "$ns" get pods -o wide --no-headers | awk -v nr="$not_ready_nodes" '
            BEGIN { n = split(nr, a, "\n"); for (i = 1; i <= n; i++) off[a[i]] = 1 }
            {
                status = $3; ready = $2; node = $8;
                if (status == "Completed") next;
                if (node in off) {
                    if (status != "Running" || ready ~ /^0\//) {
                        print "warning:" $1 " is " status " (" ready ") on NotReady node " node;
                    }
                    next;
                }
                if (status != "Running") {
                    print "error:" $1 " is " status;
                } else if (ready ~ /^0\//) {
                    print "error:" $1 " is Running but not ready (" ready ")";
                }
            }')"
        if ! grep -q '^error:' <<<"$out"; then
            break
        fi
        sleep 5
    done
    warnings="$(grep '^warning:' <<<"$out" || true)"
    errors="$(grep '^error:' <<<"$out" || true)"
    [ -n "$warnings" ] && printf '%s\n' "$warnings" >&2
    if [ -n "$errors" ]; then
        printf '%s\n' "$errors" >&2
        return 1
    fi
    return 0
}

echo "==> Check pods"
check_pods base
check_pods apps

echo "==> Check HelmChart failures"
for ns in base apps; do
    failed="$(kubectl -n "$ns" get helmcharts -o json 2>/dev/null |
        jq -r '.items[] | select(.status.conditions[]? | .type == "Failed" and .status == "True") | .metadata.name' || true)"
    if [ -n "$failed" ]; then
        echo "Error: HelmChart(s) failed in $ns: $failed" >&2
        exit 1
    fi
done

echo "==> Check restart counts"
for ns in base apps; do
    kubectl -n "$ns" get pods -o json 2>/dev/null |
        jq -r '.items[] | select(.status.containerStatuses != null) |
            .metadata.name as $pod |
            [.status.containerStatuses[].restartCount] | max as $max |
            select($max > 5) | "\($pod)\t\($max)"' |
        while IFS=$'\t' read -r pod count; do
            echo "warning: $ns/$pod has $count restarts" >&2
        done
done

echo "==> Check API readiness"
ready="$(kubectl get --raw /readyz 2>/dev/null || true)"
if [ "$ready" != "ok" ]; then
    echo "Error: API server readiness is '${ready:-unavailable}'" >&2
    exit 1
fi

echo "==> Recent warning events"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -10 || true

echo "deploy: OK (srv0)"
