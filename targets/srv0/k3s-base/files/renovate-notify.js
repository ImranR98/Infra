#!/usr/bin/env node
// DESC: Post-run Renovate notifier — publishes an ntfy message for the open
// deps-labeled PRs that a Renovate run created or refreshed. Called by
// renovate-run.sh inside the renovate-daily and renovate-infra CronJobs.
//
// Usage: renovate-notify.js --since <ISO8601> [--dry-run]
//        renovate-notify.js --test
//
// Required environment: RENOVATE_TOKEN (GitHub API), RENOVATE_REPOSITORIES
// (comma-separated owner/repo), NTFY_URL, NTFY_TOPIC, NTFY_TOKEN.
// Node's built-in fetch keeps this dependency-free in the renovate image.
'use strict';

const args = process.argv.slice(2);
let since = '';
let mode = 'publish';

for (let i = 0; i < args.length; i += 1) {
  switch (args[i]) {
    case '--since':
      since = args[i + 1] || '';
      i += 1;
      break;
    case '--dry-run':
      mode = 'dry-run';
      break;
    case '--test':
      mode = 'test';
      break;
    default:
      console.error(`unknown argument: ${args[i]}`);
      process.exit(2);
  }
}

if (mode !== 'test' && !since) {
  console.error('usage: renovate-notify.js --since <ISO8601> [--dry-run] | --test');
  process.exit(2);
}

const { NTFY_URL, NTFY_TOPIC, NTFY_TOKEN } = process.env;
const ghToken = process.env.RENOVATE_TOKEN || '';
if (mode !== 'test' && !ghToken) {
  console.error('RENOVATE_TOKEN is required');
  process.exit(1);
}

async function publish(title, message, click) {
  const payload = { topic: NTFY_TOPIC, title, message, tags: ['robot', 'package'], markdown: true };
  if (click) payload.click = click;
  const res = await fetch(`${NTFY_URL.replace(/\/+$/, '')}/`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${NTFY_TOKEN}` },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`ntfy publish failed: ${res.status} ${await res.text()}`);
}

async function repoPrs(repo) {
  const res = await fetch(
    `https://api.github.com/repos/${repo}/pulls?state=open&sort=updated&direction=desc&per_page=100`,
    {
      headers: {
        Authorization: `Bearer ${ghToken}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'infra-renovate-notify',
      },
      signal: AbortSignal.timeout(20000),
    },
  );
  if (!res.ok) throw new Error(`GitHub API failed for ${repo}: ${res.status} ${await res.text()}`);
  return res.json();
}

(async () => {
  if (mode === 'test') {
    await publish('Renovate notifier test', 'Notifier wiring works.');
    console.log('test notification published');
    return;
  }

  const repos = (process.env.RENOVATE_REPOSITORIES || '')
    .split(',')
    .map((repo) => repo.trim())
    .filter(Boolean);

  const fresh = [];
  for (const repo of repos) {
    const prs = await repoPrs(repo);
    for (const pr of prs) {
      // updated_at covers reopened PRs and force-pushed branch updates — the
      // run is the only actor that touches these branches, so it means "this
      // run". ISO-8601 UTC timestamps compare lexicographically.
      const touched = pr.created_at > since || pr.updated_at > since;
      const deps = (pr.labels || []).some((label) => label.name === 'deps');
      if (touched && deps) fresh.push({ ...pr, repo });
    }
  }

  if (fresh.length === 0) {
    console.log('no new or refreshed deps PRs');
    return;
  }

  for (const pr of fresh) {
    const line = `${pr.repo}#${pr.number} ${pr.title}`;
    if (mode === 'dry-run') console.log(line);
  }
  if (mode === 'dry-run') return;

  if (fresh.length === 1) {
    const [pr] = fresh;
    await publish(pr.title, `${pr.repo}#${pr.number}\n\n${pr.html_url}`, pr.html_url);
    console.log(`notified ${pr.repo}#${pr.number}`);
    return;
  }

  const list = fresh
    .map((pr) => `- [${pr.repo}#${pr.number}](${pr.html_url}) ${pr.title}`)
    .join('\n');
  await publish(`Renovate: ${fresh.length} PRs opened or updated`, list);
  console.log(`notified ${fresh.length} PRs in one digest`);
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
