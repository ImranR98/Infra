---
name: renovate-pr-ops
description: Triage, merge, and deploy open Renovate dependency-update PRs in the Infra homelab repo. Use when asked to review or merge Renovate PRs, handle dependency updates, or deploy already-merged updates to srv0, vps0, pc, bigpc, or rpi. Covers risk tiering (digest/patch/minor vs 0.x-minor and Kubernetes-minor), deep research for risky bumps, consent gates for risky merges and all live deploys, per-target deploy order and verification, and reporting.
---

# Renovate PR Ops

Triage, risk-assess, merge, and (after consent) deploy Renovate/deps PRs. Scope is
Renovate PRs only — branches `renovate/*`, label `deps`. Other PRs are handled
conversationally.

`AGENTS.md` is the source of truth for repo layout, deploy commands, and safety rules;
this skill encodes the recurring Renovate workflow on top of it. Skim its Targets and
K3s/Helm sections before a first run.

## Hard rules

- Never read `config/` or anything in it — secrets are private by design.
- Never merge in the GitHub platform UI. Merge locally, then push `origin master`.
- Run `bash scripts/validate.sh <target>` before every `helm upgrade --install`.
- Never commit the user's in-progress work; stash it for merges and restore it after.
- Never print secret values (variable names and paths only).
- Deploy only where this checkout has access (srv0 locally, vps0 over SSH). For
  pc/bigpc/rpi, print the commands for the user to run instead.

## Autonomy contract

| | Tier A | Tier B | Tier C |
|---|---|---|---|
| Research | quick skim | required | required, with evidence |
| Merge | autonomous | autonomous if research is clean | user consent required |
| Deploy | user consent | user consent | user consent, separate from the merge ask |

- Tier A/B merges proceed without prompting; validate each PR first.
- Every live deploy waits for explicit user go-ahead, asked once per batch: targets
  in order, exact commands, verification plan, and what stays held.
- Tier C needs consent to merge: present findings, risk, recommendation, then wait.
- An explicit user pre-authorization ("merge and deploy whatever is safe") overrides
  these gates for the named items.
- When unsure, escalate one tier.

Tier assignment (change magnitude × component criticality) is documented in
[references/risk-assessment.md](references/risk-assessment.md).

## Phase 1 — Preflight

- `git status --short`; stash WIP with `git stash push -m "renovate-pr-ops"` and
  restore with `git stash pop` when finished.
- `hostname` (expect srv0) and `kubectl get nodes` — the admin kubeconfig is root-only,
  so the user must have an unlock session running (see deploy reference if it fails).
- Ask the user for the vps0 SSH target (`user@host`) and the repo path there, then
  `ssh -A <user@host> hostname` to confirm access and `ls -d <path>` to verify the
  checkout. Never hardcode or assume either. Agent forwarding is only needed so the
  remote `git pull` can authenticate to the git host; a deploy key there removes the
  need for `-A`.
- `git fetch origin` and confirm local `master` == `origin/master`.

## Phase 2 — Triage

1. List PRs: `bash .agents/skills/renovate-pr-ops/scripts/list-prs.sh` (`--json` for raw).
2. Diff locally: `git fetch origin pull/<n>/head:renovate/pr-<n>`, then
   `git diff master...renovate/pr-<n>`. `gh` is not installed; fetching the PR ref
   avoids the diff endpoint and the anonymous API limit (60 requests/hour, enough for
   listing plus checks; set `GITHUB_TOKEN` if needed).
3. Classify each PR with the risk reference. Record the branch name, affected targets,
   and couplings (immich server+ML move together; grouped digest batches; chart + CR pairs).

## Phase 3 — Research (Tier B/C)

Work the per-type checklists in the risk reference: k3s release notes and bundled
components, app changelogs and DB migrations, digest existence and the version behind
floating tags, Helm chart value changes. Collect concrete evidence (versions, dates,
breaking-change notes, migration behavior) — it goes into the consent ask.

## Phase 4 — Merge

Per approved PR:

```bash
git fetch origin pull/<n>/head:renovate/pr-<n>
git checkout renovate/pr-<n>
bash scripts/validate.sh <target>        # every target the PR touches
git checkout master
git merge --no-ff -m "Merge pull request #<n> from <origin-owner>/<branch>" -m "<PR title>" renovate/pr-<n>
git push origin master
```

`<origin-owner>` is the account in `git remote get-url origin`. The
`Merge pull request #N from ...` subject is what makes GitHub close the PR. Verify
after pushing that the PR is no longer in `list-prs.sh` output (it reads the repo from
`origin`, so nothing is hardcoded). Restore the stash once all merges are done.

## Phase 5 — Deploy (on consent)

Push `master` first so remote checkouts can `git pull`. Present one consolidated ask,
then deploy in risk order using
[references/deploy-and-verify.md](references/deploy-and-verify.md):

1. srv0: `srv0-base`, then `srv0-apps`, inside an unlock session.
2. vps0: compose `up -d <changed services>` over SSH.
3. k3s Plan bumps (Tier C): apply `srv0-base`, then follow the upgrade-watch playbook.
4. pc/bigpc/rpi: emit the `git pull` + compose commands; do not attempt them.

## Phase 6 — Verify & report

Run the verification checklist and dead-pod cleanup from the deploy reference. Never
claim success from `helm upgrade` output alone — verify the running state.

Report format:

- **Merged** — PR number and one-line title.
- **Deployed** — target, what changed, verification result.
- **Held** — PR plus reason and evidence; what the next run should re-check.
- **Pending commands** — for machines this agent cannot reach.
