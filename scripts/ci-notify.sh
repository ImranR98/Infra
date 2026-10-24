#!/bin/bash
# DESC: Report failed GitHub Actions runs from the app repos to ntfy. Called by
# the renovate-infra CronJob after the app Renovate run. Looks back 24 hours by
# default; no notification when all runs are green.
set -euo pipefail

: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

CI_REPOS="${CI_REPOS:-ImranR98/PixelNtfy,ImranR98/ISBN-Lookup,ImranR98/apps.obtainium.imranr.dev,ImranR98/our-times,ImranR98/order-manager,ImranR98/Logtfy}"
CI_SINCE="${CI_SINCE:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"
GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required." >&2
    exit 1
fi

export GH_TOKEN CI_REPOS CI_SINCE MODE="${MODE:-publish}"

node - <<'NODE'
(async () => {
  const repos = (process.env.CI_REPOS || '').split(',').map((r) => r.trim()).filter(Boolean);
  const failures = [];

  for (const repo of repos) {
    const res = await fetch(
      `https://api.github.com/repos/${repo}/actions/runs?per_page=50`,
      {
        headers: {
          Authorization: `Bearer ${process.env.GH_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'infra-ci-notify',
        },
      },
    );
    if (!res.ok) throw new Error(`GitHub API failed for ${repo}: ${res.status} ${await res.text()}`);
    const data = await res.json();
    for (const run of data.workflow_runs || []) {
      if (run.conclusion !== 'failure') continue;
      // Only default-branch/manual runs: failed Renovate PR checks are visible
      // on the PR itself and are often transient rebases.
      if (run.event !== 'push' && run.event !== 'workflow_dispatch') continue;
      if (run.created_at < process.env.CI_SINCE) continue;
      failures.push({ repo, run });
    }
  }

  if (failures.length === 0) {
    console.log('no failed app CI runs in the last 24h');
    return;
  }

  const lines = failures.map(
    ({ repo, run }) => `- ${repo}: ${run.name} (${run.head_branch}) ${run.html_url}`,
  );
  const title = `App CI failures (${failures.length})`;
  const message = `${title}\n\n${lines.join('\n')}`;

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
  console.log(`notified ${failures.length} failed app CI run(s)`);
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
