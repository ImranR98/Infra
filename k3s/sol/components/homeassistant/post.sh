#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
source_env

# Look up the home-assistant pod (best-effort — may not exist yet on first deploy)
HA_POD=$(kubectl -n apps get pod -l "app.kubernetes.io/name=home-assistant" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$HA_POD" ]; then
	echo "Home Assistant pod not found yet (Helm controller may still be installing). Skipping config patch."
	exit 0
fi
kubectl -n apps wait --for=condition=Ready "pod/$HA_POD" --timeout=120s 2>/dev/null || {
	echo "Home Assistant pod not ready yet. Skipping config patch."
	exit 0
}

# Wait for config file (with per-attempt timeout to avoid hanging on a bad pod)
for i in $(seq 1 30); do
	timeout 10 kubectl -n apps exec "$HA_POD" -- test -f /config/configuration.yaml >/dev/null 2>&1 && break
	if [ $i -eq 30 ]; then
		echo "Config file not found after 30 attempts. Skipping config patch."
		exit 0
	fi
	sleep 2
done

# Patch trusted proxies if needed
if ! timeout 10 kubectl -n apps exec "$HA_POD" -- grep -q "use_x_forwarded_for" /config/configuration.yaml 2>/dev/null; then
	timeout 10 kubectl -n apps exec "$HA_POD" -- sh -c \
		'printf "\nhttp:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - 10.0.0.0/8\n    - 172.16.0.0/12\n  ip_ban_enabled: true\n  login_attempts_threshold: 5\n" >> /config/configuration.yaml'
	timeout 10 kubectl -n apps delete pod "$HA_POD" 2>/dev/null || true
fi
