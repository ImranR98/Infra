#!/bin/bash
# DESC: Wait for an app repo's `publish` job for a merge commit. The app CI
# builds a local image in `test`, but only the default-branch `publish` job
# pushes :sha-<commit>, verifies it, and promotes :latest. This helper uses the
# GitHub API only; it never assumes an app checkout.
# Usage: wait-for-publish.sh --repo <owner/repo> --sha <merge-sha> [--timeout 2400] [--poll 20] [--grace 90]
# Exit: 0 published or skipped, 1 failed/cancelled, 2 no run found, 3 timeout.
set -euo pipefail

repo=""
sha=""
timeout=2400
poll=20
grace=90

usage() {
    echo "Usage: $(basename "$0") --repo <owner/repo> --sha <merge-sha> [--timeout 2400] [--poll 20] [--grace 90]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --sha) sha="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --poll) poll="${2:-}"; shift 2 ;;
        --grace) grace="${2:-}"; shift 2 ;;
        -h | --help) usage ;;
        *) usage ;;
    esac
done
[ -n "$repo" ] && [ -n "$sha" ] || usage

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
if [ -f "$repo_root/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$repo_root/config/VARS.env"
    set +a
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    GITHUB_TOKEN="$RENOVATE_GITHUB_TOKEN"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "Error: no GitHub token found (GITHUB_TOKEN/RENOVATE_GITHUB_TOKEN)." >&2
    exit 1
fi
export GITHUB_TOKEN

exec python3 - "$repo" "$sha" "$timeout" "$poll" "$grace" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

repo, sha, timeout, poll, grace = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
token = os.environ["GITHUB_TOKEN"]
api = "https://api.github.com"
failed = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}


def get(path, attempt=1):
    request = urllib.request.Request(
        f"{api}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "infra-wait-publish",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (403, 429) and attempt < 4:
            time.sleep(5 * attempt)
            return get(path, attempt + 1)
        raise
    except Exception:
        if attempt >= 3:
            raise
        time.sleep(2)
        return get(path, attempt + 1)


def publish_job(run_id):
    data = get(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
    return next((job for job in data.get("jobs", []) if job.get("name") == "publish"), None)


meta = get(f"/repos/{repo}")
branch = meta["default_branch"]
started = time.time()
last_note = 0
while True:
    runs = get(f"/repos/{repo}/actions/runs?head_sha={sha}&per_page=100").get("workflow_runs", [])
    relevant = [
        run
        for run in runs
        if run.get("event") == "push"
        and run.get("head_sha") == sha
        and run.get("head_branch") == branch
    ]
    for run in relevant:
        job = publish_job(run["id"])
        if job is None:
            continue
        status = job.get("status")
        conclusion = job.get("conclusion")
        if status != "completed":
            if time.time() - last_note > 60:
                print(f"WAITING {repo} {sha[:8]} {job.get('name')} status={status} {run.get('html_url')}", flush=True)
                last_note = time.time()
            continue
        if conclusion == "success":
            print(f"PUBLISHED {repo} {sha[:8]} {run.get('html_url')}", flush=True)
            sys.exit(0)
        if conclusion == "skipped":
            print(f"SKIPPED {repo} {sha[:8]} {run.get('html_url')}", flush=True)
            sys.exit(0)
        if conclusion != "success":
            print(f"FAILED {repo} {sha[:8]} conclusion={conclusion} {run.get('html_url')}", flush=True)
            sys.exit(1)

    elapsed = time.time() - started
    if elapsed > grace and not relevant:
        print(f"NO_RUN {repo} {sha[:8]} (no default-branch publish run; likely paths-ignore)", flush=True)
        sys.exit(2)
    if elapsed > timeout:
        url = relevant[0].get("html_url", "") if relevant else ""
        print(f"TIMEOUT {repo} {sha[:8]} after {timeout}s {url}", flush=True)
        sys.exit(3)
    time.sleep(poll)
PY
