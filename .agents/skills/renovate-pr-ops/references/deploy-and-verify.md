# Deploy & verify

## Preconditions

- `master` pushed; `bash scripts/validate.sh <target>` clean for every target being deployed.
- The Infra PR being deployed is approved and merged locally. The scheduled
  Renovate runner does not merge Infra PRs. Non-allowlisted version updates are
  only proposed after the 3-day `minimumReleaseAge`; a missing update younger
  than that is expected, not a failed run.
- srv0: an unlock session is active (`bash scripts/kubeconfig-unlock.sh` holds the ACL
  until Ctrl-C). The admin kubeconfig is root-only; without the unlock, `kubectl` and
  `helm` fail with permission denied.
- Check for dirty files before helm: `helm upgrade` renders the working tree, so
  uncommitted changes would deploy too.
- Remote machines deploy from their own checkout; they must `git pull` first.

## App image → Infra PR ordering

The app image and its Infra pin are two automatic steps:

1. Renovate auto-merges the app PR (or the skill merges a ready exception).
   Record the merge commit SHA. Do not merge while `renovate/stability-days` is
   pending.
2. The app's default-branch `publish` job pushes and verifies `:sha-<commit>`
   and promotes `:latest`. Workflow-only merges are path-ignored and change no
   image.
3. The next scheduled Renovate run opens/refreshes the first-party Infra
   `docker-digests` PR immediately (the `ghcr.io/imranr98/**` allowlist).
   Third-party images wait 3 days. If a first-party pin has not appeared, the
   publish is still running/failed or the next run is pending; run
   `bash scripts/renovate.sh infra` to refresh on demand (it does not bypass the
   3-day gate). Never edit the digest by hand.
4. Validate the Infra PR, get approval, merge/push, then deploy.

## srv0 (K3s) — apply base, then apps

```bash
bash scripts/validate.sh srv0
helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace \
  -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml
helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace \
  -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml
```

`base` before `apps`; delete in reverse order if ever needed. HelmChart CRs
reconcile asynchronously via helm-controller — check its jobs/pods before
declaring success:

```bash
kubectl -n base get helmcharts
kubectl -n apps get helmcharts
for ns in base apps; do
  kubectl -n "$ns" get deploy,statefulset,daemonset -o name |
    while read -r r; do kubectl -n "$ns" rollout status "$r" --timeout=120s || echo "FAILED: $r"; done
done
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "pods OK"
kubectl get --raw /readyz
```

## srv0 compose sidecars

The public-exposure client is a host-network compose service, separate from K3s:

```bash
bash scripts/validate.sh srv0
sudo docker compose \
  --env-file config/srv0/compose.env \
  -f targets/srv0/compose/compose.yaml \
  --env-file targets/srv0/compose/.env \
  up -d public-exposure-client-wg
```

Both `--env-file` flags are required: the first carries the target config, the
second the generated machine facts (`MY_UID`, `DOCKER_GID`, state paths) and
`COMPOSE_PROFILES`. Passing any `--env-file` disables `.env` auto-discovery.
Docker requires `sudo` on these machines; if the current agent user cannot run
it non-interactively, print the command for the user to run in their shell.

## vps0 (Compose over SSH)

Ask the user for the vps0 SSH target (`user@host`) and the repo path there on every
run — never hardcode or assume them. Verify the checkout with `ls -d <repo path>`,
then:

```bash
ssh -A <user@host> 'set -e; cd <repo path> && git pull --ff-only &&
  bash scripts/validate.sh vps0'
```

Then run the Compose block on vps0 (`bash scripts/render-vps0-authelia.sh`
first when the Authelia rules changed — `validate.sh` fails if the rendered
config is stale):

```bash
sudo docker compose \
  --env-file config/vps0/compose.env \
  -f targets/vps0/compose/compose.yaml \
  -f targets/vps0/compose/compose.private.yaml \
  --env-file targets/vps0/compose/.env \
  up -d <services>
```

Confirm health with the same flags plus `ps <services>`. `-A`
(agent forwarding) is only needed so the remote `git pull` can authenticate to
the git host; a deploy key there removes the need for it.

## pc / bigpc / rpi — print these, do not run

```bash
# on the machine, in its repo checkout:
git pull
bash scripts/validate.sh <target>
sudo docker compose \
  --env-file config/<target>/compose.env \
  -f targets/<target>/compose/compose.yaml \
  --env-file targets/<target>/compose/.env \
  up -d <service>
```

Both env files are required; the machine-fact `.env` is written by
`prereqs.sh`, not by the deploy command.

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
- Compose: `sudo docker compose ... ps` healthy for every changed service; check
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
  for the new publish, then pin/refresh Infra.
