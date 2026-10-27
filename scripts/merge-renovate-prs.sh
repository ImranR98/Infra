#!/bin/bash
# DESC: Merge open Renovate PRs in the given repos once every required check
# passes. Branches that are behind the base branch are updated (triggering a
# fresh check run) before merging. Red, blocked, conflicted, or check-less PRs
# are left open and written to the report for the daily notifier. This is the
# single merge path for app PRs, the nfs derived PR, and Infra non-digest PRs.
#
# Usage:
#   merge-renovate-prs.sh --repos a/b,c/d [--only-label L] [--skip-label L]
#                         [--require-check test] [--merge-method merge|squash|rebase]
#                         [--timeout S] [--report FILE]
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi

if [ -f "$INFRA_ROOT/config/VARS.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$INFRA_ROOT/config/VARS.env"
    set +a
fi

usage() {
    echo "Usage: $(basename "$0") --repos a/b,c/d [--only-label L] [--skip-label L] [--require-check NAME] [--merge-method M] [--timeout S] [--report FILE]" >&2
}

repos=""
only_labels=""
skip_labels=""
require_checks=""
merge_method="merge"
timeout="${MERGE_TIMEOUT:-3600}"
report=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --repos) repos="${2:-}"; shift 2 ;;
        --only-label) only_labels="${only_labels:+$only_labels,}${2:-}"; shift 2 ;;
        --skip-label) skip_labels="${skip_labels:+$skip_labels,}${2:-}"; shift 2 ;;
        --require-check) require_checks="${require_checks:+$require_checks,}${2:-}"; shift 2 ;;
        --merge-method) merge_method="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        --report) report="${2:-}"; shift 2 ;;
        *)
            usage
            exit 1
            ;;
    esac
done
if [ -z "$repos" ]; then
    echo "Error: --repos is required." >&2
    exit 1
fi

GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

export GH_TOKEN REPOS="$repos" ONLY_LABELS="$only_labels" SKIP_LABELS="$skip_labels"
export REQUIRE_CHECKS="$require_checks" MERGE_METHOD="$merge_method"
export MERGE_TIMEOUT="$timeout" REPORT="$report"

# The Node loop enforces the same deadline; the shell timeout is a last resort
# for a hung request. Both leave the PR open rather than merging blind.
timeout --signal=TERM "$((timeout + 120))s" node - <<'NODE'
const fs = require('node:fs');
const { setTimeout: sleep } = require('node:timers/promises');

function withTimeout(promise, ms, what) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} timed out`)), ms)),
  ]);
}

const api = 'https://api.github.com';
const repos = (process.env.REPOS || '').split(',').map((r) => r.trim()).filter(Boolean);
const onlyLabels = (process.env.ONLY_LABELS || '').split(',').filter(Boolean);
const skipLabels = (process.env.SKIP_LABELS || '').split(',').filter(Boolean);
const requireChecks = (process.env.REQUIRE_CHECKS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const mergeMethod = process.env.MERGE_METHOD || 'merge';
const reportPath = process.env.REPORT || '';
const deadline = Date.now() + Number(process.env.MERGE_TIMEOUT || 3600) * 1000;
const failedConclusions = new Set([
  'failure',
  'timed_out',
  'cancelled',
  'action_required',
  'startup_failure',
]);

function record(kind, repo, number, reason = '') {
  const line = [kind, repo, `#${number}`, reason].join('\t');
  if (reportPath) fs.appendFileSync(reportPath, `${line}\n`);
}

async function gh(path, init = {}, attempt = 1) {
  try {
    const res = await withTimeout(
      fetch(`${api}${path}`, {
        ...init,
        headers: {
          Authorization: `Bearer ${process.env.GH_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'infra-merge-renovate',
          ...(init.headers || {}),
        },
        signal: AbortSignal.timeout(20000),
      }),
      25000,
      path,
    );
    if (!res.ok) {
      throw new Error(`${init.method || 'GET'} ${path} failed: ${res.status} ${await res.text()}`);
    }
    if (res.status === 204) return null;
    return await withTimeout(res.json(), 25000, `${path} body`);
  } catch (err) {
    if (attempt >= 3) throw err;
    await sleep(2000);
    return gh(path, init, attempt + 1);
  }
}

async function checksFor(repo, sha) {
  const data = await gh(`/repos/${repo}/commits/${sha}/check-runs?per_page=100`);
  return data.check_runs || [];
}

function requiredProblems(checks) {
  const problems = [];
  for (const name of requireChecks) {
    const runs = checks.filter((c) => c.name === name);
    if (runs.length === 0) {
      problems.push(`required check '${name}' missing`);
    } else if (runs.some((c) => c.conclusion !== 'success')) {
      problems.push(`required check '${name}' is ${runs.map((c) => c.conclusion).join('/')}`);
    }
  }
  return problems;
}

async function mergeOne(repo, number) {
  const started = Date.now();
  let zeroSince = null;
  const finish = (kind, reason = '', code = 0) => {
    record(kind, repo, number, reason);
    if (code) process.exitCode = code;
  };

  for (;;) {
    if (Date.now() > deadline) {
      console.error(`${repo} #${number}: global timeout; leaving open`);
      finish('left-open', 'global timeout');
      process.exitCode = 2;
      return;
    }
    const pr = await gh(`/repos/${repo}/pulls/${number}`);
    if (pr.state !== 'open') {
      console.log(`${repo} #${number}: already closed/merged`);
      return;
    }
    const checks = await checksFor(repo, pr.head.sha);
    const pending = checks.some((c) => c.status !== 'completed');
    const failed = checks.filter((c) => failedConclusions.has(c.conclusion));

    if (checks.length === 0) {
      zeroSince ??= Date.now();
      if (Date.now() - zeroSince > 180000) {
        console.error(`${repo} #${number}: no checks appeared; leaving open`);
        finish('left-open', 'no checks appeared');
        return;
      }
    } else {
      zeroSince = null;
    }

    if (!pending && checks.length > 0) {
      if (failed.length > 0) {
        const names = failed.map((c) => c.name).join(', ');
        console.error(`${repo} #${number}: checks failed (${names}); leaving open`);
        finish('failed', `checks failed: ${names}`);
        return;
      }

      const problems = requiredProblems(checks);
      if (problems.length > 0) {
        console.error(`${repo} #${number}: ${problems.join('; ')}; leaving open`);
        finish('left-open', problems.join('; '));
        return;
      }

      if (pr.mergeable_state === 'behind') {
        try {
          await gh(`/repos/${repo}/pulls/${number}/update-branch`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ expected_head_sha: pr.head.sha }),
          });
          console.log(`${repo} #${number}: updated behind branch; waiting for new checks`);
        } catch (err) {
          console.error(`${repo} #${number}: update-branch failed (${err.message}); leaving open`);
          finish('left-open', `update-branch failed: ${err.message}`);
          return;
        }
        await sleep(3000);
        continue;
      }

      if (pr.mergeable_state === 'dirty') {
        console.error(`${repo} #${number}: has conflicts; leaving open`);
        finish('left-open', 'merge conflicts');
        return;
      }
      if (pr.mergeable_state === 'blocked') {
        console.error(`${repo} #${number}: merge blocked; leaving open`);
        finish('left-open', 'merge blocked');
        return;
      }
      if (pr.mergeable === false) {
        await sleep(5000);
        continue;
      }
      if (pr.mergeable === true) {
        try {
          const res = await gh(`/repos/${repo}/pulls/${number}/merge`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ merge_method: mergeMethod }),
          });
          if (res?.merged) {
            console.log(`${repo} #${number}: merged`);
            finish('merged');
          } else {
            console.error(`${repo} #${number}: merge response: ${JSON.stringify(res)}`);
            finish('left-open', 'merge API did not confirm the merge');
          }
        } catch (err) {
          console.error(`${repo} #${number}: merge failed (${err.message}); leaving open`);
          finish('left-open', `merge failed: ${err.message}`);
          process.exitCode = 2;
        }
        return;
      }
    }

    if (Date.now() - started > 3600000) {
      console.error(`${repo} #${number}: timed out; leaving open`);
      finish('left-open', 'timed out');
      process.exitCode = 2;
      return;
    }
    await sleep(15000);
  }
}

(async () => {
  for (const repo of repos) {
    const prs = (await gh(`/repos/${repo}/pulls?state=open&per_page=100`)).filter((pr) => {
      if (pr.draft) return false;
      if (!String(pr.head?.ref || '').startsWith('renovate/')) return false;
      if (pr.head?.repo?.full_name && pr.head.repo.full_name !== repo) return false;
      return true;
    });

    for (const pr of prs) {
      const labels = (pr.labels || []).map((l) => l.name);
      if (onlyLabels.length > 0 && !onlyLabels.some((l) => labels.includes(l))) continue;
      if (skipLabels.some((l) => labels.includes(l))) continue;
      console.log(`${repo} #${pr.number}: ${pr.title}`);
      await mergeOne(repo, pr.number);
    }
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
