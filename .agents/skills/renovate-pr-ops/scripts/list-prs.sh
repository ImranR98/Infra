#!/bin/bash
# DESC: List open Renovate dependency PRs for the repo containing this skill.
# Uses the anonymous GitHub API, or GITHUB_TOKEN when set (higher rate limit).
# Prints one block per PR (number, updated, files, branch, labels, title, diff URL);
# --json prints the raw API objects instead.
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--json]"
    echo
    echo "Lists open PRs for the repo's origin remote, flagging Renovate PRs"
    echo "(renovate/* branch or deps label). Requires curl + python3."
    echo "Set GITHUB_TOKEN to avoid the anonymous 60 requests/hour limit."
    exit 1
}

json=false
case "${1:-}" in
    "") ;;
    --json) json=true ;;
    *) usage ;;
esac

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
if [ -z "$origin" ]; then
    echo "Error: no 'origin' remote found in $repo_root" >&2
    exit 1
fi

repo_slug="$(python3 - "$origin" <<'PY'
import re
import sys

match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", sys.argv[1])
if not match:
    sys.exit("Error: origin is not a GitHub URL: " + sys.argv[1])
print(f"{match.group(1)}/{match.group(2)}")
PY
)"

body="$(mktemp)"
headers="$(mktemp)"
trap 'rm -f "$body" "$headers"' EXIT

auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

code="$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' "${auth[@]}" \
    "https://api.github.com/repos/$repo_slug/pulls?state=open&per_page=100")" || {
    echo "Error: request to api.github.com failed (network or proxy?)" >&2
    exit 1
}

if [ "$code" != "200" ]; then
    echo "Error: GitHub API returned HTTP $code for $repo_slug" >&2
    python3 - "$body" <<'PY' >&2 || true
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("message", ""))
except Exception:
    pass
PY
    if [ "$code" = "403" ] || [ "$code" = "429" ]; then
        echo "Hint: anonymous rate limit exhausted — set GITHUB_TOKEN." >&2
    fi
    exit 1
fi

if [ "$json" = "true" ]; then
    python3 -m json.tool "$body"
else
    python3 - "$body" <<'PY'
import json
import sys

prs = json.load(open(sys.argv[1]))
if not prs:
    print("No open PRs.")
for pr in sorted(prs, key=lambda p: p["number"]):
    labels = ",".join(label["name"] for label in pr["labels"]) or "-"
    renovate = pr["head"]["ref"].startswith("renovate/") or "deps" in labels
    kind = "renovate" if renovate else "other"
    print(f"#{pr['number']}  {pr['updated_at'][:10]}  [{kind}]  {pr['head']['ref']}")
    print(f"    {pr['title']}")
    print(f"    labels={labels}")
    print(f"    diff={pr['diff_url']}")
PY
    remaining="$(grep -i '^x-ratelimit-remaining:' "$headers" | tr -d '\r' | awk '{print $2}')"
    if [ -n "$remaining" ]; then
        echo "rate-limit remaining: $remaining"
    fi
fi
