#!/bin/bash
# DESC: Post-run Renovate notifier — publishes one ntfy notification per open
# deps-labeled PR created or refreshed after the run started. Called by the
# in-cluster renovate CronJob and by scripts/renovate.sh.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") --since <ISO8601> [--repo <owner/repo>] [--dry-run]"
    echo "       $(basename "$0") --test"
    echo
    echo "  --since <ISO8601>  Only notify for PRs created or refreshed after"
    echo "                     this timestamp (a Renovate run's start time)"
    echo "  --repo <owner/repo>  Repository to query (default: ImranR98/Infra)"
    echo "  --dry-run          Print matching PRs instead of publishing"
    echo "  --test             Send a single test notification and exit"
    echo
    echo "Required environment:"
    echo "  RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN  GitHub API token"
    echo "  NTFY_URL                                 ntfy base URL"
    echo "  NTFY_TOPIC                               ntfy topic"
    echo "  NTFY_TOKEN                               ntfy write token"
    exit 1
}

since=""
repo="ImranR98/Infra"
mode="publish"
while [ $# -gt 0 ]; do
    case "$1" in
        --since)
            since="${2:-}"
            shift 2
            ;;
        --repo)
            repo="${2:-}"
            shift 2
            ;;
        --dry-run)
            mode="dry-run"
            shift
            ;;
        --test)
            mode="test"
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ "$mode" != "test" ] && [ -z "$since" ]; then
    usage
fi

: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ "$mode" != "test" ] && [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required (ships with the renovate image; install Node.js for local runs)." >&2
    exit 1
fi

export GH_TOKEN SINCE="$since" REPO="$repo" MODE="$mode"

# The GitHub response is small (open PRs, one page) and ntfy publishing is a
# single POST per PR; Node's built-in fetch keeps this dependency-free in both
# the renovate image and local runs.
node - <<'NODE'
(async () => {
  const ntfyUrl = `${process.env.NTFY_URL.replace(/\/+$/, '')}/`;
  const topic = process.env.NTFY_TOPIC;
  const ntfyHeader = { Authorization: `Bearer ${process.env.NTFY_TOKEN}` };

  async function publish(title, message, click) {
    const res = await fetch(ntfyUrl, {
      method: 'POST',
      headers: ntfyHeader,
      body: JSON.stringify({ topic, title, message, click, tags: ['robot', 'package'], markdown: true }),
    });
    if (!res.ok) throw new Error(`ntfy publish failed: ${res.status} ${await res.text()}`);
  }

  if (process.env.MODE === 'test') {
    await publish('Renovate notifier test', 'Notifier wiring works.');
    console.log('test notification published');
    return;
  }

  const res = await fetch(
    `https://api.github.com/repos/${process.env.REPO}/pulls?state=open&sort=created&direction=desc&per_page=100`,
    {
      headers: {
        Authorization: `Bearer ${process.env.GH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'infra-renovate-notify',
      },
    },
  );
  if (!res.ok) throw new Error(`GitHub API failed: ${res.status} ${await res.text()}`);

  const prs = await res.json();
  // updated_at covers reopened PRs and force-pushed branch updates — the run
  // is the only actor that touches these branches, so it means "this run".
  const fresh = prs.filter(
    (pr) =>
      (pr.created_at > process.env.SINCE || pr.updated_at > process.env.SINCE) &&
      (pr.labels || []).some((label) => label.name === 'deps'),
  );
  if (fresh.length === 0) {
    console.log('no new deps PRs');
    return;
  }

  for (const pr of fresh) {
    if (process.env.MODE === 'dry-run') {
      console.log(`#${pr.number} ${pr.created_at} ${pr.html_url}`);
      continue;
    }
    await publish(pr.title, `${pr.title}\n\n${pr.html_url}`, pr.html_url);
    console.log(`notified PR #${pr.number}: ${pr.title}`);
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
