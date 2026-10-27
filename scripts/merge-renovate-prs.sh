#!/bin/bash
# DESC: Merge open Renovate PRs in the given repos once every check passes.
# Branches that are behind the base branch are updated (triggering a fresh
# check run) before merging. Red or conflicted PRs are left for the failure
# notifier. This is the single merge path for app PRs, the nfs derived PR,
# and Infra non-digest PRs.
#
# Usage:
#   merge-renovate-prs.sh --repos a/b,c/d [--include-label L] [--skip-label L]
#                         [--merge-method merge|squash|rebase] [--timeout S]
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

GH_TOKEN="${RENOVATE_TOKEN:-${RENOVATE_GITHUB_TOKEN:-}}"
if [ -z "$GH_TOKEN" ]; then
    echo "Error: RENOVATE_TOKEN or RENOVATE_GITHUB_TOKEN is required." >&2
    exit 1
fi

repos=""
include_labels=""
skip_labels=""
merge_method="merge"
timeout="${MERGE_TIMEOUT:-3600}"
while [ $# -gt 0 ]; do
    case "$1" in
        --repos) repos="${2:-}"; shift 2 ;;
        --include-label) include_labels="${include_labels:+$include_labels,}${2:-}"; shift 2 ;;
        --skip-label) skip_labels="${skip_labels:+$skip_labels,}${2:-}"; shift 2 ;;
        --merge-method) merge_method="${2:-}"; shift 2 ;;
        --timeout) timeout="${2:-}"; shift 2 ;;
        *)
            echo "Usage: $(basename "$0") --repos a/b,c/d [--include-label L] [--skip-label L] [--merge-method M] [--timeout S]" >&2
            exit 1
            ;;
    esac
done
if [ -z "$repos" ]; then
    echo "Error: --repos is required." >&2
    exit 1
fi

export GH_TOKEN REPOS="$repos" INCLUDE_LABELS="$include_labels" SKIP_LABELS="$skip_labels"
export MERGE_METHOD="$merge_method" MERGE_TIMEOUT="$timeout"

node - <<'NODE'
const { setTimeout: sleep } = require('node:timers/promises');

const api = 'https://api.github.com';
const repos = (process.env.REPOS || '').split(',').map((r) => r.trim()).filter(Boolean);
const includeLabels = (process.env.INCLUDE_LABELS || '').split(',').filter(Boolean);
const skipLabels = (process.env.SKIP_LABELS || '').split(',').filter(Boolean);
const mergeMethod = process.env.MERGE_METHOD || 'merge';
const deadline = Date.now() + Number(process.env.MERGE_TIMEOUT || 3600) * 1000;
const failedConclusions = new Set([
  'failure',
  'timed_out',
  'cancelled',
  'action_required',
  'startup_failure',
]);

async function gh(path, init = {}, attempt = 1) {
  try {
    const res = await fetch(`${api}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${process.env.GH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'infra-merge-renovate',
        ...(init.headers || {}),
      },
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) {
      throw new Error(`${init.method || 'GET'} ${path} failed: ${res.status} ${await res.text()}`);
    }
    if (res.status === 204) return null;
    return await res.json();
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

async function mergeOne(repo, number) {
  const started = Date.now();
  let zeroSince = null;

  for (;;) {
    if (Date.now() > deadline) {
      console.error(`${repo} #${number}: global timeout; leaving open`);
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
        process.exitCode = 2;
        return;
      }
    } else {
      zeroSince = null;
    }

    if (!pending && checks.length > 0) {
      if (failed.length > 0) {
        console.error(
          `${repo} #${number}: checks failed (${failed.map((c) => c.name).join(', ')}); leaving open`,
        );
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
          return;
        }
        await sleep(3000);
        continue;
      }

      if (pr.mergeable_state === 'dirty') {
        console.error(`${repo} #${number}: has conflicts; leaving open`);
        return;
      }
      if (pr.mergeable_state === 'blocked') {
        console.error(`${repo} #${number}: merge blocked; leaving open`);
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
          console.log(
            `${repo} #${number}: ${res?.merged ? 'merged' : 'merge response: ' + JSON.stringify(res)}`,
          );
        } catch (err) {
          console.error(`${repo} #${number}: merge failed (${err.message}); leaving open`);
          process.exitCode = 2;
        }
        return;
      }
    }

    if (Date.now() - started > 3600000) {
      console.error(`${repo} #${number}: timed out; leaving open`);
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
      const included = includeLabels.length > 0 && includeLabels.some((l) => labels.includes(l));
      const skipped = skipLabels.some((l) => labels.includes(l));
      if (!included && skipped) continue;
      console.log(`${repo} #${pr.number}: ${pr.title}`);
      await mergeOne(repo, pr.number);
    }
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
