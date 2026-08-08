#!/bin/bash
# DESC: Prints the remaining manual (Home Assistant UI) steps after applying frigate
set -euo pipefail

cat <<'EOF'

====================================================================
Frigate deployed. Manual steps remaining (Home Assistant UI):
====================================================================

1. MQTT broker (once):
   Settings > Devices & Services > Add Integration > MQTT
     broker:   mosquitto
     port:     1883
     user:     homeassistant
     password: <HA_MQTT_PASSWORD from secrets/VARS.srv0.sh>

2. Frigate integration (once):
   Settings > Devices & Services > Add Integration > Frigate
     URL: http://frigate:5000

After step 2, Frigate's MQTT discovery auto-creates the camera and
event entities. Live view, detection and recordings then work end to end.
Recordings are written over NFS to srv0's $SECONDARY_STORAGE_PATH/frigate
(the pod prefers the has-amdgpu node, bigpc).

3. Smooth dashboard live view (optional): the Advanced Camera Card is
   auto-installed in Home Assistant (init container + frontend resource).
   Add it to a dashboard: Dashboard > Edit > Add Card > "Advanced Camera
   Card" > camera_entity: camera.<cam>, live_provider: mse.

Maintenance notes:
- If the rpi go2rtc password ever regenerates (password file deleted),
  update FRIGATE_RTSP_PASSWORD in secrets/VARS.srv0.sh and re-apply:
  ./infra.sh srv0 k3s deploy frigate apply
- The Frigate integration self-updates on every Home Assistant pod start
  (checks the latest GitHub release; marker at
  /config/custom_components/frigate/.installed-version).
====================================================================
EOF
