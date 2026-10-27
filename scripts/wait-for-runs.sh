#!/bin/bash
# DESC: Wait until the app/derived GitHub Actions activity triggered by the
# daily Renovate run has settled: no in-flight default-branch push runs, no
# in-flight Renovate PR runs, and no Renovate PR still waiting to merge.
# Exit 0 when settled, 2 on timeout.
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

GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

since=""
timeout="${WAIT_TIMEOUT:-1800}"
settle="${WAIT_SETTLE:-60}"
poll="${WAIT_POLL:-60}"
while [ $# -gt 0 ]; do
    case "$1" in
        --since) since="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --settle) settle="${2:-}"; shift 2 ;;
        --poll) poll="${2:-}"; shift 2 ;;
        *) echo "Usage: $(basename "$0") --since <ISO8601> [--timeout s] [--settle s] [--poll s]" >&2; exit 1 ;;
    esac
done
if [ -z "$since" ]; then
    echo "Error: --since is required." >&2
    exit 1
fi

export GH_TOKEN INFRA_REPO CI_REPOS
export WAIT_SINCE="$since" WAIT_TIMEOUT="$timeout" WAIT_SETTLE="$settle" WAIT_POLL="$poll"

timeout --signal=TERM "$((timeout + 60))s" node - <<'NODE'
const { setTimeout: sleep } = require('node:timers/promises');

const api = 'https://api.github.com';
const repos = (process.env.CI_REPOS || '').split(',').filter(Boolean);
const infra = process.env.INFRA_REPO;
const since = new Date(process.env.WAIT_SINCE).getTime();
const timeoutMs = Number(process.env.WAIT_TIMEOUT) * 1000;
const settleMs = Number(process.env.WAIT_SETTLE) * 1000;
const pollMs = Number(process.env.WAIT_POLL) * 1000;
const failedConclusions = new Set([
  'failure',
  'timed_out',
  'cancelled',
  'action_required',
  'startup_failure',
]);

async function gh(path, attempt = 1) {
  try {
    const res = await fetch(`${api}${path}`, {
      headers: {
        Authorization: `Bearer ${process.env.GH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'infra-wait-runs',
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

const defaultBranch = new Map();

(async () => {
  const started = Date.now();
  let quietSince = null;

  for (;;) {
    let busy = false;

    for (const repo of repos) {
      if (!defaultBranch.has(repo)) {
        const meta = await gh(`/repos/${repo}`);
        defaultBranch.set(repo, meta.default_branch);
      }
      const branch = defaultBranch.get(repo);

      const runs = (await gh(`/repos/${repo}/actions/runs?per_page=100`)).workflow_runs || [];
      const relevant = runs.filter((run) => {
        if (new Date(run.created_at).getTime() < since) return false;
        if (run.event === 'push' && run.head_branch === branch) return true;
        if (run.event === 'pull_request' && String(run.head_branch || '').startsWith('renovate/')) {
          return true;
        }
        return false;
      });
      if (relevant.some((run) => run.status !== 'completed')) {
        busy = true;
      }

      const prs = (await gh(`/repos/${repo}/pulls?state=open&per_page=100`)).filter((pr) =>
        String(pr.head?.ref || '').startsWith('renovate/'),
      );
      for (const pr of prs) {
        const checks = (await gh(`/repos/${repo}/commits/${pr.head.sha}/check-runs?per_page=100`))
          .check_runs || [];
        if (checks.length === 0) {
          const age = Date.now() - new Date(pr.created_at || pr.updated_at).getTime();
          if (age < 180000) busy = true;
          continue;
        }
        if (checks.some((c) => c.status !== 'completed')) {
          busy = true;
          continue;
        }
        if (checks.some((c) => failedConclusions.has(c.conclusion))) continue;
        // Green but still open: do not block on a queued auto-merge. Many PRs
        // are "behind" the base branch and will be rebased on the next run; the
        // settle window below catches a merge that happens right after the last
        // check completes.
      }
    }

    // Infra: only push runs matter (the derived PR is merged separately).
    if (!defaultBranch.has(infra)) {
      const meta = await gh(`/repos/${infra}`);
      defaultBranch.set(infra, meta.default_branch);
    }
    const infraBranch = defaultBranch.get(infra);
    const infraRuns = (await gh(`/repos/${infra}/actions/runs?per_page=100`)).workflow_runs || [];
    const infraRelevant = infraRuns.filter(
      (run) =>
        new Date(run.created_at).getTime() >= since &&
        run.event === 'push' &&
        run.head_branch === infraBranch,
    );
    if (infraRelevant.some((run) => run.status !== 'completed')) busy = true;

    if (busy) {
      quietSince = null;
      if (Date.now() - started > timeoutMs) {
        console.error('timed out waiting for runs to settle');
        process.exit(2);
      }
      await sleep(pollMs);
      continue;
    }

    quietSince ??= Date.now();
    if (Date.now() - quietSince >= settleMs) {
      console.log('all app/derived runs settled');
      return;
    }
    await sleep(pollMs);
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
