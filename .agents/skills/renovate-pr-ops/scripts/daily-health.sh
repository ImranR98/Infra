#!/bin/bash
# DESC: Health-check the scheduled renovate-daily CronJob before PR triage.
# Prints the CronJob's last schedule/success, the newest Job's final status (including
# manual reruns), each pod attempt's termination reason, and Renovate's
# Error/Warning lines. The runner is a pure Renovate pass; there are no wrapper
# phase markers.
# Exit 0 = run healthy, in progress, or recovered by a retry/manual rerun;
#      1 = failed, stale, suspended, or missing;
#      2 = cannot determine (no kubectl/python3, or no cluster access).
# Env: RENOVATE_NAMESPACE (base), RENOVATE_CRONJOB (renovate-daily),
#      RENOVATE_MAX_AGE_SECONDS (93600 = 26h, matches the Grafana stale alert).
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--help]"
    echo
    echo "Reports the health of the scheduled renovate-daily CronJob on srv0."
    echo "Run in the kubeconfig unlock session. Exit: 0 healthy/in progress/recovered,"
    echo "1 failed/stale/suspended/missing, 2 cannot determine."
}

case "${1:-}" in
    "") ;;
    -h | --help) usage; exit 0 ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
    echo "UNKNOWN: kubectl is not installed." >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "UNKNOWN: python3 is required." >&2
    exit 2
fi

exec python3 - "${RENOVATE_NAMESPACE:-base}" "${RENOVATE_CRONJOB:-renovate-daily}" \
    "${RENOVATE_MAX_AGE_SECONDS:-93600}" <<'PY'
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

namespace, cronjob, max_age_raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    max_age = int(max_age_raw)
except ValueError:
    print(f"UNKNOWN: RENOVATE_MAX_AGE_SECONDS must be an integer, got {max_age_raw!r}")
    sys.exit(2)

now = datetime.now(timezone.utc)
phase_re = re.compile(r"^==> \[(\d+)/9\] (.*)$")
scheduled_re = re.compile(rf"^{re.escape(cronjob)}-\d+$")
merge_note_re = re.compile(
    r"^\S+ #\d+: .*(leaving open|did not confirm|timed out|global timeout)"
)


def run(*args, timeout=90):
    try:
        return subprocess.run(
            ["kubectl", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None


def one_line(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[-1] if lines else ""


def get_json(*args):
    proc = run(*args, "-o", "json")
    if proc is None:
        return None, "kubectl timed out"
    if proc.returncode != 0:
        return None, one_line(proc.stderr or proc.stdout)
    try:
        return json.loads(proc.stdout), ""
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON: {exc}"


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def age(ts):
    if ts is None:
        return "unknown"
    seconds = int((now - ts).total_seconds())
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    hours, rem = divmod(seconds, 3600)
    return f"{sign}{hours}h{rem // 60:02d}m"


def duration(start, end):
    if not start or not end:
        return ""
    seconds = int((end - start).total_seconds())
    if seconds < 0:
        return ""
    minutes, secs = divmod(seconds, 60)
    return f"{minutes}m{secs:02d}s"


def pod_state(pod):
    status = pod.get("status") or {}
    for container in status.get("containerStatuses") or []:
        terminated = (container.get("state") or {}).get("terminated")
        if terminated:
            return (
                terminated.get("reason", "Terminated"),
                terminated.get("exitCode"),
                parse_ts(terminated.get("startedAt")),
                parse_ts(terminated.get("finishedAt")),
            )
    return status.get("phase", "Unknown"), None, parse_ts(status.get("startTime")), None


def pod_logs(name):
    proc = run("-n", namespace, "logs", f"pod/{name}", "--tail=-1", timeout=120)
    if proc is None:
        return None, "kubectl logs timed out"
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout).strip()
    return proc.stdout.splitlines(), ""


def summarise(lines):
    phases, errors, warnings = [], [], []
    for line in lines:
        match = phase_re.match(line)
        if match:
            phases.append((int(match.group(1)), match.group(2)))
        elif line.startswith("Error:") or line.startswith("ERROR:"):
            errors.append(line.rstrip())
        elif merge_note_re.match(line):
            errors.append(line.rstrip())
        elif line.startswith("Warning:"):
            warnings.append(line.rstrip())
    return phases, errors, warnings


cron, err = get_json("-n", namespace, "get", f"cronjob/{cronjob}")
if cron is None:
    if "cronjobs.batch" in err and "not found" in err.lower():
        print(f"VERDICT: MISSING — {namespace}/{cronjob} does not exist (check the base chart).")
        sys.exit(1)
    print(f"UNKNOWN: cannot read {namespace}/{cronjob}: {err}")
    print("Hint: the admin kubeconfig is root-only; start scripts/kubeconfig-unlock.sh.")
    sys.exit(2)

jobs_doc, err = get_json("-n", namespace, "get", "jobs")
if jobs_doc is None:
    print(f"UNKNOWN: cannot list Jobs in {namespace}: {err}")
    print("Hint: the admin kubeconfig is root-only; start scripts/kubeconfig-unlock.sh.")
    sys.exit(2)

jobs = [
    job
    for job in jobs_doc.get("items") or []
    if (job.get("metadata") or {}).get("name", "").startswith(f"{cronjob}-")
]
jobs.sort(key=lambda job: (job.get("metadata") or {}).get("creationTimestamp", ""))

spec = cron.get("spec") or {}
status = cron.get("status") or {}
last_schedule = parse_ts(status.get("lastScheduleTime"))
last_success = parse_ts(status.get("lastSuccessfulTime"))
active = status.get("active") or []
suspend = bool(spec.get("suspend"))

print(f"CronJob {namespace}/{cronjob}")
print(
    f"  schedule: {spec.get('schedule', '?')} "
    f"({spec.get('timeZone', 'cluster default')})  suspend: {suspend}"
)
print(f"  last schedule: {status.get('lastScheduleTime', 'never')} ({age(last_schedule)})")
print(f"  last success:  {status.get('lastSuccessfulTime', 'never')} ({age(last_success)})")
print(f"  active:        {len(active)}")

if suspend:
    print("VERDICT: SUSPENDED — the CronJob will not run (spec.suspend=true).")
    sys.exit(1)

if not jobs:
    print("  latest job:    none")
    print("VERDICT: NEVER RAN — no Job found; the schedule may have been missed or the CronJob just created.")
    sys.exit(1)

latest = jobs[-1]
latest_name = latest["metadata"]["name"]
latest_status = latest.get("status") or {}
conditions = {
    condition.get("type"): condition.get("status")
    for condition in latest_status.get("conditions") or []
}
complete = conditions.get("Complete") == "True" or bool(latest_status.get("completionTime"))
failed = conditions.get("Failed") == "True"
succeeded = latest_status.get("succeeded") or 0
failed_attempts = latest_status.get("failed") or 0
active_pods = latest_status.get("active") or 0
created = parse_ts(latest["metadata"].get("creationTimestamp"))
manual = not scheduled_re.match(latest_name)

state = "Complete" if complete else "Failed" if failed else "Running" if active_pods else "Unknown"
print(f"  latest job:    {latest_name} ({'manual rerun' if manual else 'scheduled'})")
print(
    f"    status: {state}  succeeded={succeeded} "
    f"failed-attempts={failed_attempts} active={active_pods}"
)

pods_doc, pods_err = get_json("-n", namespace, "get", "pods", "-l", "app=renovate")
pods = []
if pods_doc is None:
    print(f"    attempts: unavailable ({pods_err})")
else:
    for pod in pods_doc.get("items") or []:
        labels = (pod.get("metadata") or {}).get("labels") or {}
        owners = (pod.get("metadata") or {}).get("ownerReferences") or []
        job_name = labels.get("job-name") or next(
            (owner.get("name") for owner in owners if owner.get("kind") == "Job"), None
        )
        if job_name == latest_name:
            pods.append(pod)
    pods.sort(key=lambda pod: (pod.get("metadata") or {}).get("creationTimestamp", ""))
    if not pods:
        print("    attempts: no pods retained (logs unavailable)")
    for index, pod in enumerate(pods, start=1):
        pod_name = (pod.get("metadata") or {}).get("name", "?")
        reason, code, started, finished = pod_state(pod)
        suffix = f" exit {code}" if code is not None else ""
        took = duration(started, finished)
        print(f"    {index}. {pod_name}: {reason}{suffix}{' (' + took + ')' if took else ''}")
        lines, log_err = pod_logs(pod_name)
        if lines is None:
            print(f"       logs unavailable: {log_err}")
            continue
        phases, errors, warnings = summarise(lines)
        if phases:
            reached = ", ".join(str(number) for number, _ in phases)
            print(f"       phases: {reached} (last: [{phases[-1][0]}/9] {phases[-1][1]})")
        else:
            print("       phases: n/a (pure Renovate run)")
        if errors:
            print("       issues:")
            for line in errors[-10:]:
                print(f"         {line}")
        if warnings:
            print("       warnings:")
            for line in warnings[-10:]:
                print(f"         {line}")

if complete:
    stale = bool(last_schedule and (now - last_schedule).total_seconds() > max_age)
    if stale and not manual:
        print(
            f"VERDICT: STALE — the last scheduled run started {age(last_schedule)} ago "
            f"(threshold {max_age // 3600}h); check the CronJob/controller."
        )
        sys.exit(1)
    if failed_attempts > 0:
        print(
            "VERDICT: RECOVERED — the latest attempt succeeded after a failed attempt; "
            "read its errors for partial merges/notifications."
        )
    else:
        print("VERDICT: OK — the latest attempt completed successfully.")
    if manual and stale:
        print(
            "  note: this was a manual rerun; the last scheduled run was "
            f"{age(last_schedule)} ago — check the schedule/controller."
        )
    sys.exit(0)

if failed:
    print("VERDICT: FAILED — the latest attempt failed; use the phase/error lines above.")
    sys.exit(1)

if active_pods:
    running_for = (now - created).total_seconds() if created else 0
    if running_for > 2 * 3600 + 600:
        print(
            f"VERDICT: HUNG — active for {age(created)} (activeDeadlineSeconds=7200); "
            "inspect the pod before deleting anything."
        )
        sys.exit(1)
    print(f"VERDICT: IN PROGRESS — running for {age(created)}; re-check when it completes.")
    sys.exit(0)

print("VERDICT: FAILED — Job is neither Complete nor visibly running (controller state?)")
sys.exit(1)
PY
