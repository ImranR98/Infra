#!/bin/bash
# DESC: Cross-repo Renovate inventory for the Infra repo and every APP_REPOS
# entry. Lists open Renovate PRs with their checks, recent app merges (for the
# app -> publish -> Infra refresh ordering), and failed default-branch CI runs.
# Uses the GitHub API only; never assumes an app checkout.
# Usage: list-prs.sh [--recent [HOURS]]   (default: 24h)
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--recent [HOURS]]"
    echo
    echo "Lists open Renovate PRs across INFRA_REPO and APP_REPOS, plus recent"
    echo "merged Renovate PRs and failed default-branch CI runs. Default recent"
    echo "window: 24 hours. Requires curl + python3 and a GitHub token."
    exit 1
}

recent_hours=24
case "${1:-}" in
    "") ;;
    --recent)
        recent_hours="${2:-24}"
        case "$recent_hours" in
            '' | *[!0-9]*) usage ;;
        esac
        ;;
    *) usage ;;
esac

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"

if [ -z "${INFRA_REPO:-}" ] && [ -f "$repo_root/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$repo_root/config/VARS.env"
    set +a
fi

origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
if [ -z "${INFRA_REPO:-}" ] && [ -n "$origin" ]; then
    INFRA_REPO="$(python3 - "$origin" <<'PY'
import re
import sys
match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", sys.argv[1])
print(f"{match.group(1)}/{match.group(2)}" if match else "")
PY
)"
fi
if [ -z "${INFRA_REPO:-}" ]; then
    echo "Error: set INFRA_REPO in config/VARS.env (or use a GitHub origin remote)." >&2
    exit 1
fi

# Resolve the token without printing it.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${RENOVATE_GITHUB_TOKEN:-}" ]; then
    GITHUB_TOKEN="$RENOVATE_GITHUB_TOKEN"
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$repo_root/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$repo_root/config/VARS.env"
    set +a
    GITHUB_TOKEN="${RENOVATE_GITHUB_TOKEN:-}"
fi
if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GITHUB_TOKEN
else
    echo "Error: no GitHub token found (GITHUB_TOKEN/RENOVATE_GITHUB_TOKEN)." >&2
    exit 1
fi

export INFRA_REPO APP_REPOS="${APP_REPOS:-}"

exec python3 - "$recent_hours" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

hours = int(sys.argv[1])
token = os.environ.get("GITHUB_TOKEN", "")
infra = os.environ["INFRA_REPO"]
apps = [repo.strip() for repo in os.environ.get("APP_REPOS", "").split(",") if repo.strip()]
repos = [infra] + [repo for repo in apps if repo != infra]
api = "https://api.github.com"
failed_conclusions = {"failure", "timed_out", "action_required", "startup_failure"}
since = datetime.now(timezone.utc) - timedelta(hours=48)


def get(url, attempt=1):
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "infra-renovate-inventory",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)
    except Exception:
        if attempt >= 3:
            raise
        import time

        time.sleep(2)
        return get(url, attempt + 1)


def parse_ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def is_renovate(pr):
    branch = str((pr.get("head") or {}).get("ref", ""))
    labels = [label.get("name") for label in pr.get("labels") or []]
    return branch.startswith("renovate/") or "deps" in labels


def check_summary(repo, pr):
    try:
        checks = get(f"{api}/repos/{repo}/commits/{pr['head']['sha']}/check-runs?per_page=100").get(
            "check_runs", []
        )
    except Exception as exc:
        return f"checks: unavailable ({exc})"
    failed = [check for check in checks if check.get("conclusion") in failed_conclusions]
    pending = [check for check in checks if check.get("status") != "completed"]
    if not checks:
        return "checks: none"
    lines = [f"checks: {len(failed)} failed, {len(pending)} pending"]
    for check in failed[:5]:
        lines.append(f"    - {check.get('name')}: {check.get('conclusion')} {check.get('html_url') or ''}".rstrip())
    for check in pending[:5]:
        lines.append(f"    - {check.get('name')}: {check.get('status')}")
    return "\n".join(lines)


def recent_merges(repo, cutoff):
    try:
        prs = get(f"{api}/repos/{repo}/pulls?state=closed&per_page=100&sort=updated&direction=desc")
    except Exception as exc:
        return f"recent merges: unavailable ({exc})"
    merged = []
    for pr in prs:
        if not is_renovate(pr) or not pr.get("merged_at"):
            continue
        merged_at = parse_ts(pr.get("merged_at"))
        if merged_at is None or merged_at < cutoff:
            continue
        merged.append(
            f"  MERGED #{pr['number']} sha={pr.get('merge_commit_sha') or '?'} "
            f"at={pr['merged_at']} {pr.get('title', '')[:110]}"
        )
    if not merged:
        return f"recent merges ({hours}h): none"
    return f"recent merges ({hours}h): {len(merged)}\n" + "\n".join(merged)


def ci_failures(repo, branch):
    try:
        runs = get(
            f"{api}/repos/{repo}/actions/runs?branch={urllib.parse.quote(branch)}&event=push&per_page=100"
        ).get("workflow_runs", [])
    except Exception as exc:
        return f"CI failures (48h): unavailable ({exc})"
    newest = {}
    for run in runs:
        created = parse_ts(run.get("created_at"))
        if created is None or created < since:
            continue
        key = run.get("workflow_id")
        if key not in newest or created > newest[key][0]:
            newest[key] = (created, run)
    failures = [run for _, run in newest.values() if run.get("conclusion") == "failure"]
    if not failures:
        return "CI failures (48h): none"
    lines = [f"CI failures (48h): {len(failures)}"]
    for run in failures[:5]:
        lines.append(f"  - {run.get('name')} {run.get('html_url')}")
    return "\n".join(lines)


exit_code = 0
for repo in repos:
    try:
        meta = get(f"{api}/repos/{repo}")
        branch = meta["default_branch"]
        prs = [
            pr
            for pr in get(f"{api}/repos/{repo}/pulls?state=open&per_page=100")
            if is_renovate(pr)
        ]
        kind = "infra" if repo == infra else "app"
        print(f"\n== {repo} ({kind}) default={branch}")
        print(f"open Renovate PRs: {len(prs)}")
        for pr in sorted(prs, key=lambda item: item["number"]):
            detail = get(f"{api}/repos/{repo}/pulls/{pr['number']}")
            labels = ",".join(label["name"] for label in detail.get("labels") or []) or "-"
            mergeable = detail.get("mergeable_state") or ("mergeable" if detail.get("mergeable") else "unknown")
            print(
                f"  #{detail['number']} {detail['head']['ref']} updated={detail['updated_at'][:10]} "
                f"mergeable={mergeable} labels={labels}"
            )
            print(f"    {detail.get('title', '')[:120]}")
            print(f"    head={detail['head']['sha']}")
            print("    " + check_summary(repo, detail).replace("\n", "\n    "))
        print(recent_merges(repo, datetime.now(timezone.utc) - timedelta(hours=hours)))
        print(ci_failures(repo, branch))
    except Exception as exc:
        print(f"\n== {repo}: unavailable ({exc})")
        exit_code = 1

sys.exit(exit_code)
PY
