# Falco query and verification recipes

## Dashboard first

Grafana → Dashboards → **Falco**:

- **Falco Overview** — event stats, rates by priority/node, top rules,
  recent events. Set the time range to the window you are reviewing and use
  the `rule`, `priority`, `node`, and search filters.
- **Falco Health** — DaemonSet/scrape status, drops, CPU/memory, and the
  "Rules matched in range" table.

The dashboards are the visual cross-check; `falco-events.py` is the grouped,
redacted source for exception proposals.

## Script

```bash
# last 24h, warning+critical, summary
python3 .agents/skills/falco-exception-triage/scripts/falco-events.py \
  --since 24h --priority Warning,Critical --format summary

# focus on an app / pod / image substring
python3 .agents/skills/falco-exception-triage/scripts/falco-events.py \
  --since 12h --app dscpln,file-pipelines,task-runner

# exact window; UTC is used in output
python3 .agents/skills/falco-exception-triage/scripts/falco-events.py \
  --from 2026-10-25T22:00:00Z --to 2026-10-26T08:00:00Z

# proposals for apply-exceptions.py
python3 .agents/skills/falco-exception-triage/scripts/falco-events.py \
  --since 24h --priority Warning,Critical --format yaml \
  > /tmp/opencode/falco-proposals.yaml

# include notices and test events
... --priority all --include-test --format summary
```

The script starts a temporary `kubectl -n base port-forward svc/loki` on a free
port and closes it. If the kubeconfig is locked, run
`bash scripts/kubeconfig-unlock.sh` in another terminal. To reuse an existing
port-forward:

```bash
python3 .../falco-events.py --loki-url http://127.0.0.1:13107 --since 6h
```

The Loki stream is
`{namespace="base", app="falco", container="falco"}`. The top-level Falco JSON
fields are `priority`, `rule`, `hostname`, `output`, `output_fields`. The
script looks at `k8s.ns.name`, `k8s.pod.name`, `container.name`,
`container.image.repository`, `proc.name`, `proc.exename`, `proc.pname`,
`proc.cmdline`, `fd.name`, and `user.name`.

Command lines are redacted before printing. Never dump raw `output_fields`:
the pre-fix logtfy event still contains its service-account token in
`proc.cmdline`. If Loki read access is a boundary, rotate the logtfy SA token.

## True-positive tests

After applying an exception, use a **fresh** namespace and pod name; the
exceptions for app pods are pod-prefix-scoped.

```bash
kubectl create namespace falco-tp-test

# Read sensitive file untrusted (Warning)
kubectl -n falco-tp-test run falco-tp-read --rm -i --restart=Never \
  --image=busybox:1.38 -- sh -c 'cat /etc/shadow >/dev/null'

# Drop and execute new binary in container (Critical)
kubectl -n falco-tp-test run falco-tp-drop --rm -i --restart=Never \
  --image=busybox:1.38 -- sh -c 'cp /bin/busybox /tmp/tpbin; chmod +x /tmp/tpbin; /tmp/tpbin true'

kubectl delete namespace falco-tp-test
```

Wait for the next scrape/evaluation and confirm the rule still fires. The
`Netcat Remote Code Execution` rule requires `nc -e`/`-c` (or `ncat` exec
flags), not plain `nc`; the event-generator covers it.

## Optional event-generator

The event-generator is a **fire drill for the rules**, not a false-alarm
source: it deliberately performs the benign-but-suspicious actions the rules
look for (read `/etc/shadow`, `nc`, write `/etc`, ptrace, memfd, etc.) in a
throwaway container.

Use it after the exception pass to verify the rules you kept still fire, or
before enabling alerts. It creates many test events; run it in its own
namespace and delete it after. The skill's script ignores that namespace.

```bash
kubectl create namespace falco-eg-sandbox
kubectl -n falco-eg-sandbox run event-generator \
  --image=falcosecurity/event-generator:0.13.0 \
  --restart=Never -- run syscall
kubectl -n falco-eg-sandbox logs -f event-generator
kubectl delete namespace falco-eg-sandbox
```

`run syscall` runs the stable syscall actions once. Do not use `k8saudit`
actions or `--all` unless you intend to create K8s resources. Some
privileged-only actions (mount, debugfs, ptrace, namespace changes) may fail in
an unprivileged pod; run a separate privileged test pod only in the sandbox
namespace if you need those rules exercised.

## Alert verification

The Grafana alert rules live in the **Falco** folder. To verify the end-to-end
path without touching production pods, create a `falco-alert-test` namespace
and a pod that triggers a Critical rule (e.g. the `falco-tp-drop` command
above). Wait for the next metrics scrape + Grafana evaluation, check the
Grafana alert state/notification history, then delete the namespace. The
`falco-alert-test` prefix is ignored by the skill.
