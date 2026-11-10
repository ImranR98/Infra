#!/bin/bash
# DESC: Scheduled Renovate entrypoint — run the pass, then notify about the
# deps PRs it opened or refreshed. Mounted into the renovate-daily CronJob
# from the renovate-scripts ConfigMap.
set -uo pipefail

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

renovate "$@"
rc=$?

# The notifier is best-effort: a failure here must not turn a good Renovate
# run into a failed Job, and a failed run is already covered by the Grafana
# job-failed/stale alerts. It still runs after a non-zero renovate exit
# because PRs opened earlier in the pass are worth reporting.
if [ "$rc" -ne 0 ]; then
    echo "renovate exited $rc; checking for PRs opened before the failure" >&2
fi
node /opt/renovate/renovate-notify.js --since "$start" ||
    echo "warning: Renovate PR notifier failed (run result unaffected)" >&2

exit "$rc"
