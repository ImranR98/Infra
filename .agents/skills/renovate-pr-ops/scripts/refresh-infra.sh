#!/bin/bash
# DESC: Run the suspended renovate-infra CronJob as a one-off Job, wait for it,
# then wait for the new/updated Infra Renovate PR. Used after app image
# publishes so a fresh digest PR appears without waiting for the scheduled run.
# Requires kubectl access (the kubeconfig unlock session) and a GitHub token.
# Usage: refresh-infra.sh [--dry-run] [--timeout 1800] [--active-timeout 1800] [--poll 20]
# Exit: 0 Infra PR ready, 1 Renovate Job failed, 2 no new PR, 3 timeout,
#       4 another Renovate Job stayed active.
set -euo pipefail

dry_run=0
timeout=1800
active_timeout=1800
poll=20
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --active-timeout) active_timeout="${2:-}"; shift 2 ;;
        --poll) poll="${2:-}"; shift 2 ;;
        -h | --help)
            echo "Usage: $(basename "$0") [--dry-run] [--timeout 1800] [--active-timeout 1800] [--poll 20]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
if [ -f "$repo_root/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$repo_root/config/VARS.env"
    set +a
fi
if [ -z "${INFRA_REPO:-}" ]; then
    echo "Error: set INFRA_REPO in config/VARS.env." >&2
    exit 1
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    GITHUB_TOKEN="$RENOVATE_GITHUB_TOKEN"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "Error: no GitHub token found (GITHUB_TOKEN/RENOVATE_GITHUB_TOKEN)." >&2
    exit 1
fi
export GITHUB_TOKEN INFRA_REPO

namespace=base
cronjob=renovate-infra
job="renovate-infra-manual-$(date -u +%Y%m%d%H%M%S)"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is not installed." >&2
    exit 1
fi
if ! kubectl -n "$namespace" get "cronjob/$cronjob" >/dev/null 2>&1; then
    echo "Error: cannot read $namespace/$cronjob (is the kubeconfig unlock session running?)" >&2
    exit 1
fi

# Do not overlap the scheduled all-repos run or another on-demand run.
deadline=$((SECONDS + active_timeout))
while :; do
    active="$(kubectl -n "$namespace" get jobs -o json 2>/dev/null |
        jq -r '.items[] | select((.metadata.name | test("^renovate-(daily|infra)-")) and ((.status.active // 0) > 0)) | .metadata.name' |
        head -1)"
    [ -z "$active" ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "BUSY another Renovate Job is active: $active" >&2
        exit 4
    fi
    echo "WAITING_ACTIVE $active"
    sleep 10
done

run_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$dry_run" = 1 ]; then
    echo "DRY-RUN would create: kubectl -n $namespace create job --from=cronjob/$cronjob $job"
    exec python3 - "$INFRA_REPO" "$run_start" <<'PY'
import json, os, sys, urllib.request
repo, run_start = sys.argv[1], sys.argv[2]
token = os.environ["GITHUB_TOKEN"]
request = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/pulls?state=open&per_page=100",
    headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "infra-refresh"},
)
with urllib.request.urlopen(request, timeout=25) as response:
    prs = json.load(response)
for pr in prs:
    if str(pr.get("head", {}).get("ref", "")).startswith("renovate/"):
        labels = ",".join(label["name"] for label in pr.get("labels") or [])
        print(f"OPEN #{pr['number']} updated={pr['updated_at']} labels={labels} {pr['title'][:100]}")
PY
    exit 0
fi

kubectl -n "$namespace" create job --from="cronjob/$cronjob" "$job" >/dev/null
echo "created $namespace/$job"

if ! kubectl -n "$namespace" wait --for=condition=complete "job/$job" --timeout="${timeout}s" >/dev/null 2>&1; then
    echo "FAILED $namespace/$job did not complete" >&2
    kubectl -n "$namespace" get "job/$job" -o wide >&2 || true
    kubectl -n "$namespace" logs "job/$job" --tail=200 2>&1 |
        grep -E '^ ?(ERROR|WARN):' | tail -20 >&2 || true
    exit 1
fi
echo "completed $namespace/$job"
kubectl -n "$namespace" delete "job/$job" >/dev/null 2>&1 || true

exec python3 - "$INFRA_REPO" "$run_start" "$timeout" "$poll" <<'PY'
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone

repo, run_start_raw, timeout, poll = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
token = os.environ["GITHUB_TOKEN"]
started = datetime.fromisoformat(run_start_raw.replace("Z", "+00:00"))


def get(path):
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "infra-refresh"},
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response)


deadline = time.time() + timeout
while True:
    prs = get(f"/repos/{repo}/pulls?state=open&per_page=100&sort=updated&direction=desc")
    fresh = []
    for pr in prs:
        if not str(pr.get("head", {}).get("ref", "")).startswith("renovate/"):
            continue
        try:
            updated = datetime.fromisoformat(pr["updated_at"].replace("Z", "+00:00"))
        except ValueError:
            continue
        if updated < started.replace(microsecond=0):
            continue
        labels = [label["name"] for label in pr.get("labels") or []]
        fresh.append((pr, labels))
    if fresh:
        for pr, labels in fresh:
            marker = "DIGEST" if "infra-digest-pin" in labels else "INFRA"
            print(f"{marker} #{pr['number']} updated={pr['updated_at']} labels={','.join(labels) or '-'} {pr['title'][:110]}")
        sys.exit(0)
    if time.time() > deadline:
        print("NO_NEW_PR (Renovate completed; no new/updated Infra Renovate PR)")
        sys.exit(2)
    time.sleep(poll)
PY
