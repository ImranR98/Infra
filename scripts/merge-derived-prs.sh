#!/bin/bash
# DESC: Merge the open derived-image PR (nfs-server dependency updates) once
# all of its checks pass. The PR is opened by the derived-only Renovate pass;
# Renovate's own automerge cannot reliably wait for the image build test, so
# the daily job owns this merge.
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

export GH_TOKEN INFRA_REPO DERIVED_LABEL
export MERGE_TIMEOUT="${MERGE_TIMEOUT:-1200}"
export POLL_SECONDS="${POLL_SECONDS:-15}"

node - <<'NODE'
const { setTimeout: sleep } = require('node:timers/promises');

const api = 'https://api.github.com';
const repo = process.env.INFRA_REPO;
const label = process.env.DERIVED_LABEL;
const timeoutMs = Number(process.env.MERGE_TIMEOUT) * 1000;
const pollMs = Number(process.env.POLL_SECONDS) * 1000;
const failedConclusions = new Set([
  'failure',
  'timed_out',
  'cancelled',
  'action_required',
  'startup_failure',
]);

async function gh(path, init = {}) {
  const res = await fetch(`${api}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${process.env.GH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'infra-merge-derived',
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    throw new Error(`${init.method || 'GET'} ${path} failed: ${res.status} ${await res.text()}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

async function checksFor(sha) {
  const data = await gh(`/repos/${repo}/commits/${sha}/check-runs?per_page=100`);
  return data.check_runs || [];
}

(async () => {
  const prs = (await gh(`/repos/${repo}/pulls?state=open&per_page=100`)).filter(
    (pr) =>
      !pr.draft &&
      (pr.labels || []).some((l) => l.name === label),
  );

  if (prs.length === 0) {
    console.log('no open derived-image PR');
    return;
  }

  for (const pr of prs) {
    console.log(`derived PR #${pr.number}: ${pr.title}`);
    const started = Date.now();
    let checks = [];
    let zeroSince = null;

    for (;;) {
      checks = await checksFor(pr.head.sha);
      const pending = checks.some((c) => c.status !== 'completed');
      const failed = checks.filter((c) => failedConclusions.has(c.conclusion));

      if (checks.length === 0) {
        zeroSince ??= Date.now();
        if (Date.now() - zeroSince > 180000) {
          console.error(`PR #${pr.number}: no check runs appeared; leaving open`);
          process.exitCode = 2;
          break;
        }
      } else {
        zeroSince = null;
      }

      if (!pending && checks.length > 0) {
        if (failed.length > 0) {
          console.error(
            `PR #${pr.number}: checks failed (${failed.map((c) => c.name).join(', ')}); leaving open`,
          );
          break;
        }
        const merged = await gh(`/repos/${repo}/pulls/${pr.number}/merge`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ merge_method: 'merge' }),
        });
        console.log(
          `PR #${pr.number}: ${merged?.merged ? 'merged' : 'merge response: ' + JSON.stringify(merged)}`,
        );
        break;
      }

      if (Date.now() - started > timeoutMs) {
        console.error(`PR #${pr.number}: timed out waiting for checks; leaving open`);
        process.exitCode = 2;
        break;
      }
      await sleep(pollMs);
    }
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
