---
name: falco-exception-triage
description: Triage Falco false alarms from Loki and add scoped exceptions to the srv0 custom rules. Use when a new app or workload triggers noisy Falco warnings/errors, or when asked to add Falco exceptions for a time range, app/pod/namespace, rule, or priority. Proposes narrow exceptions, applies/validates them, optionally deploys with consent, and verifies the remaining rules still fire.
---

# Falco Exception Triage

Falco runs in `base` on srv0 and bigpc; its custom rules are file-backed at
`targets/srv0/k3s-base/files/falco/custom-rules.yaml`. `AGENTS.md` is the source
of truth for repo layout and deploy commands.

## Hard rules

- Never print, commit, or echo secret values or raw command lines.
  `falco-events.py` redacts command lines; do not bypass it or dump raw
  `output_fields`.
- Never add a global or tag-wide exception. Scope by `k8s.ns.name`,
  `k8s.pod.name` prefix, `proc.name`, and (for file rules) `fd.name`.
- Never auto-suppress a high-signal rule: netcat/reverse shell, crypto miner,
  release_agent, memfd/fileless execution, kernel module, or an unexpected
  `Drop and execute`. A known browser/downloader process in a known pod may be
  proposed, but it is critical and needs consent.
- Never suppress test/one-off pods (`falco-selftest-*`, `falco-api-selftest`,
  `falco-alert-test-*`, `falco-eg-sandbox`, `event-generator`) unless the user
  explicitly asks. The script marks them `[test]` and omits them from YAML.
- Do not read `config/` or Grafana/ntfy secrets. Query Loki through a
  port-forward (`falco-events.py` does this).
- Do not deploy without user go-ahead. Always run `scripts/validate.sh srv0`
  first.
- After applying an exception, verify a true positive from a fresh pod or
  namespace (see `references/query-recipes.md`). Never "verify" from the pod
  you just excepted.

## Inputs

Ask for, or infer:
- time range: `--since 24h`, or `--from`/`--to` (ISO 8601)
- app/pod/namespace substring: `--app dscpln,task-runner`
- optional: `--priority` (default `Emergency,Alert,Critical,Error,Warning`),
  `--rule`, `--namespace`
- action: propose (default) or apply

If the user says "new app" without naming it, query the default priorities and
ask which pod/namespace is the new one before applying.

## Workflow

1. **Preflight**
   - `git status --short`
   - `kubectl get nodes` (kubeconfig is root-only; if it fails, ask the user to
     run `bash scripts/kubeconfig-unlock.sh` in another terminal)
   - `kubectl -n base get ds falco`
2. **Collect**
   - Summary:
     `python3 .agents/skills/falco-exception-triage/scripts/falco-events.py --since 24h --priority Warning,Critical --format summary`
   - Proposals:
     `... --format yaml > /tmp/opencode/falco-proposals.yaml`
   - The script groups by priority/rule/host/namespace/pod prefix/process/file,
     counts and times the events, redacts command lines, and marks test pods.
3. **Classify** using `references/false-alarm-recipes.md`:
   - `TEST` — ignore and say why.
   - `HOST` — `container.name=host` + `proc.name` (e.g. game anti-cheat).
   - `APP` — namespace + pod prefix + process (add `fd.name` for file rules).
   - `INFRA` — known controllers/jobs (helm-install, immich-seed,
     crowdsec-cert-roll, headlamp, alloy-operator).
   - `TRUE POSITIVE` — do not suppress.
4. **Propose** the exact exception blocks and a one-line scope per rule. Use
   the consent table below. A critical rule or a broad scope is a stop-and-ask.
5. **Apply**
   - `python3 .../apply-exceptions.py --input /tmp/opencode/falco-proposals.yaml`
   - `bash scripts/validate.sh srv0`
   - Deploy only with the user's go-ahead:
     `helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml`
6. **Verify**
   - `kubectl -n base rollout status ds/falco`
   - Confirm `custom-rules.yaml | schema validation: ok` in the Falco log.
   - Re-query the time window **after** the rollout for the excluded
     rule/pod; expect zero new events.
   - Run a true-positive test in a fresh namespace (see references) and confirm
     the rule still fires.
7. **Report** counts, exceptions, scopes, verification, and residual risk.
   Commit only if asked (local; do not push unless asked).

## Consent

| Case | Action |
|---|---|
| Notice/Warning, known app, narrow scope | Apply after showing the proposed blocks; deploy with go-ahead |
| Critical rule, known app/process | Explicit per-rule consent unless the user pre-authorized that exact app/rule |
| Broad/global, unknown, or high-signal rule | Do not apply; present the evidence and ask |

The user can pre-authorize in the request, e.g. "FlareSolverr chromedriver and
RocketLeague ptrace are normal; add those."

## References

- `references/false-alarm-recipes.md` — patterns for this stack, including the
  current host-game, browser, backup, init-container, controller/job, app-cron,
  and Home Assistant cases.
- `references/exception-schema.md` — Falco exception syntax, the list-of-rows
  rule, quoting `=`, append vs replace, unique names, and output redaction.
- `references/query-recipes.md` — Loki fields, time ranges, the Falco
  dashboards, true-positive tests, and the optional event-generator.
