#!/bin/bash
# DESC: Assert every app repo's renovate.json keeps the shared baseline:
# standard extends, OSV alerts, dependency dashboard, replace range strategy,
# a release-age delay, lockfile maintenance where a lockfile exists, and no
# Renovate/platform automerge (the daily merge helper is the only merge path).
# Run locally or from renovate-daily.sh; exits non-zero on drift.
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

export GH_TOKEN APP_REPOS

node - <<'NODE'
const { setTimeout: sleep } = require('node:timers/promises');

function withTimeout(promise, ms, what) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} timed out`)), ms)),
  ]);
}

const api = 'https://api.github.com';
const repos = (process.env.APP_REPOS || '').split(',').map((r) => r.trim()).filter(Boolean);
const baseExtends = [
  'config:recommended',
  'docker:pinDigests',
  'helpers:pinGitHubActionDigests',
  'security:minimumReleaseAgeNpm',
  ':configMigration',
];
const automergeKeys = ['automerge', 'automergeType', 'automergeStrategy', 'platformAutomerge'];

async function gh(path, init = {}, attempt = 1) {
  try {
    const res = await withTimeout(
      fetch(`${api}${path}`, {
        ...init,
        headers: {
          Authorization: `Bearer ${process.env.GH_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'infra-check-app-configs',
          ...(init.headers || {}),
        },
        signal: AbortSignal.timeout(20000),
      }),
      25000,
      path,
    );
    if (res.status === 404) return null;
    if (!res.ok) {
      throw new Error(`GET ${path} failed: ${res.status} ${await res.text()}`);
    }
    return await withTimeout(res.json(), 25000, `${path} body`);
  } catch (err) {
    if (attempt >= 3) throw err;
    await sleep(2000);
    return gh(path, init, attempt + 1);
  }
}

function analyse(cfg, hasLockfile) {
  const problems = [];
  const ext = Array.isArray(cfg.extends) ? cfg.extends : [];
  for (const preset of baseExtends) {
    if (!ext.includes(preset)) problems.push(`extends is missing '${preset}'`);
  }

  for (const key of automergeKeys) {
    if (Object.prototype.hasOwnProperty.call(cfg, key)) {
      problems.push(`top-level '${key}' must not be set`);
    }
    (cfg.packageRules || []).forEach((rule, index) => {
      if (Object.prototype.hasOwnProperty.call(rule, key)) {
        problems.push(`packageRules[${index}] '${key}' must not be set`);
      }
    });
  }

  if (cfg.osvVulnerabilityAlerts !== true) {
    problems.push('osvVulnerabilityAlerts must be true');
  }
  if (cfg.dependencyDashboard !== true) {
    problems.push('dependencyDashboard must be true');
  }
  if (cfg.rangeStrategy !== 'replace') {
    problems.push("rangeStrategy must be 'replace'");
  }
  if (typeof cfg.minimumReleaseAge !== 'string' || !cfg.minimumReleaseAge.trim()) {
    problems.push('minimumReleaseAge must be a non-empty string');
  }
  if (hasLockfile && cfg.lockFileMaintenance?.enabled !== true) {
    problems.push('lockFileMaintenance.enabled must be true (package-lock.json present)');
  }
  return problems;
}

(async () => {
  let failures = 0;

  for (const repo of repos) {
    const meta = await gh(`/repos/${repo}`);
    if (!meta?.default_branch) {
      console.log(`FAIL ${repo}`);
      console.log('     - repository metadata unavailable');
      failures += 1;
      continue;
    }
    const branch = encodeURIComponent(meta.default_branch);
    const file = await gh(`/repos/${repo}/contents/renovate.json?ref=${branch}`);
    if (!file?.content) {
      console.log(`FAIL ${repo}`);
      console.log('     - renovate.json is missing or unreadable');
      failures += 1;
      continue;
    }
    const lockfile = await gh(`/repos/${repo}/contents/package-lock.json?ref=${branch}`);

    let cfg;
    try {
      cfg = JSON.parse(Buffer.from(file.content, file.encoding || 'base64').toString('utf8'));
    } catch (err) {
      console.log(`FAIL ${repo}`);
      console.log(`     - renovate.json is not valid JSON: ${err.message}`);
      failures += 1;
      continue;
    }

    const problems = analyse(cfg, Boolean(lockfile));
    if (problems.length > 0) {
      console.log(`FAIL ${repo}`);
      for (const problem of problems) console.log(`     - ${problem}`);
      failures += 1;
    }
  }

  if (failures > 0) {
    console.error(`\n${failures} of ${repos.length} app Renovate configs drifted from the baseline.`);
    process.exit(1);
  }
  console.log(`app Renovate configs match the baseline (${repos.length} repos)`);
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
NODE
