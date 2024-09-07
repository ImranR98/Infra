#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$HERE"/../state/homeassistant

echo "===
NOTE
===
You may need to manually add the following lines to configuration.yaml in the container, then restart the service:

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.244.0.0/16
  ip_ban_enabled: true
  login_attempts_threshold: 5"