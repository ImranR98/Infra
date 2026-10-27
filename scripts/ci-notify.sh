#!/bin/bash
# DESC: Report failed GitHub Actions runs (app repos + Infra) and failed `test`
# checks on open Renovate PRs to ntfy. One digest; no notification when clean.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi

# shellcheck disable=SC1091
. "$INFRA_ROOT/scripts/repos.sh"

if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$INFRA_ROOT/config/VARS.env"
    set +a
fi

: "${NTFY_URL:?NTFY_URL is required}"
: "${NTFY_TOPIC:?NTFY_TOPIC is required}"
: "${NTFY_TOKEN:?NTFY_TOKEN is required}"

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

export GH_TOKEN APP_REPOS INFRA_REPO CI_SINCE MODE="${MODE:-publish}"

node - <<'NODE'
const api = 'https://api.github.com';
const repos = [...(process.env.APP_REPOS || '').split(','), process.env.INFRA_REPO].filter(Boolean);
const failedConclusions = new Set([
  'failure',
  'timed_out',
  'cancelled',
  'action_required',
  'startup_failure',
]);
const since = new Date(process.env.CI_SINCE).getTime();

const { setTimeout: sleep } = require('node:timers/promises');

async function gh(path, attempt = 1) {
  try {
    const res = await fetch(`${api}${path}`, {
      headers: {
        Authorization: `Bearer ${process.env.GH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'infra-ci-notify',
      },
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) throw new Error(`GET ${path} failed: ${res.status} ${await res.text()}`);
    return await res.json();
  } catch (err) {
    if (attempt >= 3) throw err;
    await sleep(2000);
    return gh(path, attempt + 1);
  }
}

(async () => {
  const failures = [];

  for (const repo of repos) {
    const runs = (await gh(`/repos/${repo}/actions/runs?per_page=100`)).workflow_runs || [];
    // A newer success clears an older failure on the same workflow/branch/event.
    const latest = new Map();
    for (const run of runs) {
      if (new Date(run.created_at).getTime() < since) continue;
      const key = `${run.workflow_id}:${run.event}:${run.head_branch}`;
      const prev = latest.get(key);
      if (!prev || new Date(run.created_at) > new Date(prev.created_at)) latest.set(key, run);
    }
    for (const run of latest.values()) {
      if (run.conclusion !== 'failure') continue;
      // Renovate PR failures are reported below from the PR's newest `test`
      // check, which covers older failed runs too.
      if (run.event === 'pull_request' && String(run.head_branch || '').startsWith('renovate/')) {
        continue;
      }
      failures.push({
        repo,
        label: `${run.name} (${run.event}/${run.head_branch})`,
        url: run.html_url,
      });
    }

    const prs = (await gh(`/repos/${repo}/pulls?state=open&per_page=100`)).filter((pr) =>
      String(pr.head?.ref || '').startsWith('renovate/'),
    );
    for (const pr of prs) {
      const checks = (await gh(`/repos/${repo}/commits/${pr.head.sha}/check-runs?per_page=100`))
        .check_runs || [];
      const testRuns = checks
        .filter((c) => c.name === 'test')
        .sort((a, b) => {
          const at = a.started_at ? Date.parse(a.started_at) : 0;
          const bt = b.started_at ? Date.parse(b.started_at) : 0;
          return bt - at || (b.id || 0) - (a.id || 0);
        });
      const test = testRuns[0];
      if (test && failedConclusions.has(test.conclusion)) {
        failures.push({
          repo,
          label: `PR #${pr.number}: ${pr.title} (test ${test.conclusion})`,
          url: pr.html_url,
        });
      }
    }
  }

  if (failures.length === 0) {
    console.log('no failed app/Infra CI runs or Renovate PR tests');
    return;
  }

  const lines = failures.map((f) => `- ${f.repo}: ${f.label} ${f.url}`);
  const title = `CI failures (${failures.length})`;
  const message = `${title}\n\n${lines.join('\n')}`;

  if (process.env.MODE === 'dry-run') {
    console.log(message);
    return;
  }

  const res = await fetch(`${process.env.NTFY_URL.replace(/\/+$/, '')}/`, {
    method: 'POST',
    signal: AbortSignal.timeout(15000),
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
  console.log(`notified ${failures.length} failure(s)`);
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
