# Falco false-alarm recipes

Use these as hypotheses, not blind rules. Confirm the pod/process/file in the
events, then scope the exception as narrowly as the data allows.

## Host games / anti-cheat (bigpc)

RocketLeague under Steam/Proton/Wine calls `ptrace` for Easy Anti-Cheat:

```yaml
- rule: PTRACE attached to process
  exceptions:
    - name: rocket_league_eac_host
      fields: [container.name, proc.name]
      comps: ["=", "="]
      values:
        - [host, RocketLeague_EA]
  override:
    exceptions: append
```

The same process also produces `PTRACE anti-debug attempt` (Notice); add a
separate exception if you want the log clean. Other Proton games have different
`proc.name` values; add one per game, never a host-wide `container.name=host`
exception.

## Browser automation

FlareSolverr, Selenium/Chromium (Task Runner's browser sidecar), Playwright
(Linkwarden), and similar services spawn drivers/helpers from the writable
layer. Expect `Drop and execute new binary`, `PTRACE`, `Change thread
namespace`, `Packet socket`, `Unexpected UDP traffic`, `Run shell untrusted`,
and `Contact K8S API` (for the app's own API use).

Example (the Critical FlareSolverr case):

```yaml
- rule: Drop and execute new binary in container
  exceptions:
    - name: flaresolverr_chromedriver
      fields: [k8s.ns.name, k8s.pod.name, proc.name]
      comps: ["=", startswith, "="]
      values:
        - [apps, flaresolverr-, chromedriver]
  override:
    exceptions: append
```

Scope by the app's pod prefix + the driver/helper process. Do not suppress
`Drop and execute` for a browser app by image alone; a malicious binary with a
different process name should still fire. Critical exceptions require consent.

## Backups, restic, ssh, git

Task Runner backups, restic, rsync/ssh, and D$CPLN pipelines read keys and
credentials and spawn shells. Expect `Read sensitive file untrusted`,
`Search private keys or passwords`, `Redirect STDOUT/STDIN to network`,
`Run shell untrusted`, `Launch remote file copy tools`, and sometimes
`Contact K8S API` (kubectl-based jobs).

Scope by pod prefix + process, and add `fd.name` when the rule is a file rule:

```yaml
- rule: Read sensitive file untrusted
  exceptions:
    - name: backup_task_ssh_keys
      fields: [k8s.ns.name, k8s.pod.name, proc.name, fd.name]
      comps: ["=", startswith, "=", "="]
      values:
        - [apps, task-runner-, ssh, /home/imranr/.ssh/id_ed25519]
  override:
    exceptions: append
```

Prefer a pod/process scope over a path-only scope. Paths change; pod prefixes
are stable across rollouts.

## Init containers and package managers

Home Assistant's integration installer, opencode/Homebrew/npm, and Renovate can
trigger `Package Management in Container`, `Drop and execute new binary`, and
`Run shell untrusted` during startup or dependency work.

Scope by pod prefix + process, e.g. Home Assistant's installer, not the whole
`apps` namespace. If the process name is generic (`sh`, `python3`, `node`), keep
the namespace + pod prefix and add the parent/command if needed.

## Renovate's containerbase Node tool

Renovate's image runs `npm`/`node` from `/opt/containerbase/tools/node/…`, which
lives in the writable layer and trips `Drop and execute new binary in
container` (Critical) on every run. The actual Renovate process from the base
image does not trip it.

```yaml
- rule: Drop and execute new binary in container
  exceptions:
    - name: renovate_containerbase_node
      fields: [k8s.ns.name, k8s.pod.name, proc.name, proc.exe]
      comps: ["=", startswith, "=", startswith]
      values:
        - [base, renovate-, node, /opt/containerbase/tools/node/]
  override:
    exceptions: append
```

Use `renovate-` (not just `renovate-apps-`) so the infra/pr-watch CronJobs are
covered. The `proc.exe` prefix keeps the Critical rule active for any other
binary dropped into a Renovate pod.

## Kubernetes controllers and jobs

These legitimately call the API server:

| Pod prefix | Process | Why |
|---|---|---|
| `helm-install-` | `helm`, `mapkubeapis` | helm-controller |
| `immich-seed-` | `kubectl` | Immich seeding hook |
| `crowdsec-cert-roll-` | `kubectl` | hourly cert rotation |
| `headlamp-` | `headlamp-server` | Headlamp UI |
| `k8s-monitoring-alloy-operator-` | `helm-operator` | Alloy operator |

Scope `Contact K8S API Server From Container` by namespace + pod prefix +
process. Never add a `proc.name=curl` or `proc.name=kubectl` global exception:
the rule is a useful compromise signal for app pods.

## App cron wrappers

FreshRSS runs `sh -c php …/actualize_script.php` from its own cron:

```yaml
- rule: Run shell untrusted
  exceptions:
    - name: freshrss_cron_shell
      fields: [k8s.ns.name, k8s.pod.name, proc.name]
      comps: ["=", startswith, "="]
      values:
        - [apps, freshrss-, sh]
  override:
    exceptions: append
```

This is a Notice. Scope it to the app pod; don't suppress `sh` globally.

## Home Assistant packet sockets

HA uses `AF_PACKET` for local discovery:

```yaml
- rule: Packet socket created in container
  exceptions:
    - name: homeassistant_packet_socket
      fields: [k8s.ns.name, k8s.pod.name, proc.name]
      comps: ["=", startswith, "="]
      values:
        - [apps, homeassistant-, python3]
  override:
    exceptions: append
```

## Host DNF log rotation

`dnf5 makecache` rotates/clears `/var/log/dnf5.log*` on the host and can trip
`Clear Log Activities` (Warning):

```yaml
- rule: Clear Log Activities
  exceptions:
    - name: host_dnf5_log_rotation
      fields: [container.name, proc.name, fd.name]
      comps: ["=", "=", startswith]
      values:
        - [host, dnf5, /var/log/dnf5.log]
  override:
    exceptions: append
```

Keep the `fd.name` prefix: another host process clearing a different log, or
dnf5 touching a non-log file, should still fire.

## Test and one-off pods

Never add production exceptions for:

- `falco-selftest-*`, `falco-api-selftest`
- `falco-alert-test-*`
- `falco-eg-sandbox`, `event-generator`
- one-off `kubectl run` pods and manual `kubectl exec -it` sessions

The script marks them `[test]` and omits them from `--format yaml`. Use a time
range after the test, or the dashboard search, to keep them out of the review.

## Rules that should stay alerting

Do not suppress these from normal app noise; they are the reason to keep Falco:

- `Netcat Remote Code Execution in Container`
- `Detect crypto miners using the Stratum protocol`
- `Detect release_agent File Container Escapes`
- `Fileless execution via memfd_create`
- `Linux Kernel Module Injection Detected`
- `Drop and execute new binary in container` outside a known browser pod
- `PTRACE attached to process` outside a known game/debugger process
- `Contact K8S API Server From Container` from an app pod that has no reason to
  use the API

If one of these fires from a new app, investigate before proposing an
exception.
