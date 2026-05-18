#!/bin/bash
# Migrate existing Home Assistant installations to use trusted proxies.
# This is only needed for installs that existed before the chart's built-in
# configuration management was enabled. New installs get trusted proxies
# from the chart's initContainer automatically.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
source_env

HA_POD=$(kubectl -n apps get pod -l "app.kubernetes.io/name=home-assistant" \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$HA_POD" ]; then exit 0; fi

kubectl -n apps wait --for=condition=Ready "pod/$HA_POD" --timeout=120s 2>/dev/null || exit 0

if timeout 10 kubectl -n apps exec "$HA_POD" -- grep -q "use_x_forwarded_for" /config/configuration.yaml 2>/dev/null; then
	exit 0
fi

kubectl -n apps exec "$HA_POD" -- sh -c \
	'printf "\nhttp:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - 10.0.0.0/8\n    - 172.16.0.0/12\n  ip_ban_enabled: true\n  login_attempts_threshold: 5\n" >> /config/configuration.yaml'
