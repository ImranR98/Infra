# Deploy & verify

## Preconditions

- `master` pushed; `bash scripts/validate.sh <target>` clean for every target being deployed.
- The Infra PR being deployed is approved and merged locally. The scheduled
  Renovate runner does not merge Infra PRs.
- srv0: an unlock session is active (`bash scripts/kubeconfig-unlock.sh` holds the ACL
  until Ctrl-C). The admin kubeconfig is root-only; without the unlock, `kubectl` and
  `helm` fail with permission denied.
- Check for dirty files before helm: `helm upgrade` renders the working tree, so
  uncommitted changes would deploy too.
- Remote machines deploy from their own checkout; they must `git pull` first.

## App image → Infra PR ordering

An Infra digest PR is only meaningful after the app image publish succeeded:

1. Merge/confirm the app PR with a squash via the GitHub API (or let Renovate
   auto-merge it). Record the merge commit SHA.
2. Wait for the app's default-branch `publish` job:
   `wait-for-publish.sh --repo <repo> --sha <sha>`.
   - `PUBLISHED`: the image and digest exist.
   - `SKIPPED`/`NO_RUN`: no runtime image changed; no Infra refresh needed.
   - `FAILED`/`TIMEOUT`: do not treat the new digest as available.
3. Run `refresh-infra.sh` once after all app publishes settle. It creates an
   Infra-only Renovate Job and waits for the new/updated Infra PR.
4. Triage/merge the resulting Infra PR (human gate), then deploy.

Do not run the Infra refresh while an app publish is in flight; the digest would
be stale.

## srv0 (K3s) — apply base, then apps

Preferred path (validates, upgrades both charts, waits for the helm-controller jobs
and workload rollouts, then checks pods, HelmChart failures, restart counts, and
`/readyz`; workloads only on NotReady nodes are warned and skipped):

```bash
bash scripts/deploy.sh srv0
```

Raw fallback:

```bash
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
```

`base` before `apps`; delete in reverse order if ever needed. HelmChart CRs reconcile
asynchronously via helm-controller — check its jobs/pods before declaring success.

## srv0 compose sidecars

The public-exposure client is a host-network compose service, separate from K3s:

```bash
bash scripts/compose.sh srv0 up -d public-exposure-client-wg
```

The wrapper needs access to the Docker socket. If the current agent user cannot
open it, print the command for the user to run in their shell.

## vps0 (Compose over SSH)

Ask the user for the vps0 SSH target (`user@host`) and the repo path there on every
run — never hardcode or assume them. Verify the checkout with `ls -d <repo path>`,
then:

```bash
ssh -A <user@host> 'set -e; cd <repo path> && git pull --ff-only &&
  bash scripts/compose.sh vps0 up -d <services>'
```

Then run `bash scripts/compose.sh vps0 ps <services>` to confirm health. `-A`
(agent forwarding) is only needed so the remote `git pull` can authenticate to
the git host; a deploy key there removes the need for it.

## pc / bigpc / rpi — print these, do not run

```bash
# on the machine, in its repo checkout:
git pull
bash scripts/compose.sh <target> up -d <service>
```

The machine-fact `.env` is supplied by the wrapper; no extra `--env-file`.

## Verification checklist

- `kubectl get pods -A --no-headers | grep -vE 'Running|Completed'` — only pre-existing
  failures remain; investigate anything new before reporting success.
- `kubectl -n apps rollout status deploy/<name> --timeout=120s` for each affected app.
- `kubectl -n base get helmcharts` and `kubectl -n apps get helmcharts` — no FAILED.
- `kubectl get pvc -A --no-headers | grep -v Bound` — no unbound or lost PVCs
  (`nfs-apps` is the default StorageClass).
- `kubectl get --raw /readyz` — `ok`.
- `kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail`
  — no new post-deploy warnings.
- Running images match the merged tags:
  `kubectl -n apps get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}'`.
- StatefulSets (for example Open WebUI) are checked with `get statefulset`, not
  `get deploy`.
- Compose: `docker compose ... ps` healthy for every changed service; check
  `docker logs --tail 20 <svc>` on auth/data services for startup errors.
- Public edge: `curl -sS -o /dev/null -w '%{http_code}' https://<host>` for a
  representative app, and a control-plane request through the public-exposure
  tunnel.

## Upgrade-watch playbook (k3s Plan bumps)

1. Apply `srv0-base`; both Plans flip to the new version and the controller creates
   `apply-server-plan-*` / `apply-agent-plan-*` jobs (concurrency 1, cordon on).
2. Agent-plan waits for server-plan (its `prepare` references it).
3. Watch with `kubectl -n system-upgrade get plans,jobs,pods`. During a node restart
   the original job pod goes `Unknown` and the job controller spawns a replacement —
   expected; the replacement finishes the job.
4. Nodes go `SchedulingDisabled`, then `Ready` at the new version; roughly 4 minutes
   per node.
5. After both Plans report COMPLETE and nodes are Ready/uncordoned, re-run the full
   verification checklist (PVCs, apps, readyz).
6. The srv0 k3s restart clears the kubeconfig ACL — the user must re-run
   `bash scripts/kubeconfig-unlock.sh` afterwards.
7. To keep watching through the API blip, snapshot the unlocked kubeconfig to a 0600
   temp file (`install -m 600 /etc/rancher/k3s/k3s.yaml /tmp/k3s-watch.yaml`, then
   `KUBECONFIG=/tmp/k3s-watch.yaml kubectl ...`) and delete it when done. Never change
   permissions on the real file and never leave a permanent `KUBECONFIG`.

## Troubleshooting

- Plan not progressing: inspect `kubectl -n system-upgrade get plans -o yaml`
  (status/conditions) and `kubectl -n system-upgrade logs job/<job> -c upgrade`. A
  stalled job usually means a node failed to restart k3s — check on the node
  (`systemctl status k3s`, journal) rather than forcing a re-run.
- Pre-existing failures (for example a failed nightly state-backup run) are not caused
  by the deploy — triage them separately and say so explicitly.
- Orphaned `Unknown`/`Error` pods are safe to delete once their owning job is
  Complete/Failed; leave Completed job pods as history.
- A failed app publish is not fixed by deploying Infra. Fix the app CI first, wait
  for the new publish, then refresh Infra.
