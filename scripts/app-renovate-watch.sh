#!/bin/bash
# DESC: Watch open app-repo Renovate PRs for failed `test` checks and post one
# ntfy digest. This covers the case where a major update is held by tests and
# would otherwise sit silently until someone opens the PR list.
set -euo pipefail

INFRA_ROOT="${INFRA_ROOT:-/repo}"
if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$INFRA_ROOT/config/VARS.env"
    set +a
fi

: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

APP_REPOS="${APP_REPOS:-ImranR98/DSCPLN-Workflows,ImranR98/DSCPLN,ImranR98/PixelNtfy,ImranR98/ISBN-Lookup,ImranR98/apps.obtainium.imranr.dev,ImranR98/our-times,ImranR98/order-manager,ImranR98/Logtfy}"
MODE="${MODE:-publish}"
if [ "${1:-}" = "--dry-run" ]; then
    MODE=dry-run
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required." >&2
    exit 1
fi

export GH_TOKEN APP_REPOS MODE AUTH_TOKEN="$GH_TOKEN"

node - <<'NODE'
(async () => {
  const repos = (process.env.APP_REPOS || '').split(',').map((r) => r.trim()).filter(Boolean);
  const failures = [];

  for (const repo of repos) {
    const res = await fetch(
      `https://api.github.com/repos/${repo}/pulls?state=open&per_page=100`,
      {
        headers: {
          Authorization: `Bearer ${process.env.AUTH_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'infra-app-renovate-watch',
        },
      },
    );
    if (!res.ok) {
      console.error(`GitHub API failed for ${repo} pulls: ${res.status} ${await res.text()}`);
      continue;
    }
    const pulls = await res.json();
    for (const pr of pulls) {
      if (!pr.head?.ref?.startsWith('renovate/')) continue;
      const checksRes = await fetch(
        `https://api.github.com/repos/${repo}/commits/${pr.head.sha}/check-runs?per_page=100`,
        {
          headers: {
            Authorization: `Bearer ${process.env.AUTH_TOKEN}`,
            Accept: 'application/vnd.github+json',
            'User-Agent': 'infra-app-renovate-watch',
          },
        },
      );
      if (!checksRes.ok) {
        console.error(`GitHub API failed for ${repo}#${pr.number} checks: ${checksRes.status} ${await checksRes.text()}`);
        continue;
      }
      const checks = await checksRes.json();
      const testRuns = (checks.check_runs || []).filter((c) => c.name === 'test');
      // A re-run or reopened PR can have several `test` check runs. Only the
      // newest one is authoritative; an older failure must not override a new
      // pending/successful run.
      testRuns.sort((a, b) => {
        const at = a.started_at ? Date.parse(a.started_at) : 0;
        const bt = b.started_at ? Date.parse(b.started_at) : 0;
        return bt - at || (b.id || 0) - (a.id || 0);
      });
      const test = testRuns[0];
      if (test?.conclusion === 'failure') {
        failures.push({
          repo,
          number: pr.number,
          title: pr.title,
          url: pr.html_url,
          ageHours: Math.max(0, Math.floor((Date.now() - new Date(pr.created_at).getTime()) / 3600000)),
        });
      }
    }
  }

  if (failures.length === 0) {
    console.log('no failing app Renovate PRs');
    return;
  }

  const title = `App Renovate PRs failing tests (${failures.length})`;
  const message = `${title}\n\n${failures
    .map((f) => `- ${f.repo}#${f.number} (${f.ageHours}h): ${f.title}\n  ${f.url}`)
    .join('\n')}`;

  if (process.env.MODE === 'dry-run') {
    console.log(message);
    return;
  }

  const ntfyUrl = `${process.env.NTFY_URL.replace(/\/+$/, '')}/`;
  const res = await fetch(ntfyUrl, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.NTFY_TOKEN}` },
    body: JSON.stringify({
      topic: process.env.NTFY_TOPIC,
      title,
      message,
      tags: ['warning'],
      markdown: true,
    }),
  });
  if (!res.ok) throw new Error(`ntfy publish failed: ${res.status} ${await res.text()}`);
  console.log(`notified ${failures.length} failing app Renovate PR(s)`);
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
