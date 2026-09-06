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

The Home Assistant Frigate dashboard is auto-provisioned (sidebar > Frigate).
It uses core HA cards only (no custom components):
- Live:               picture-entity card (go2rtc-backed stream from the
                      integration; verified stream_source in camera.py).
- Alerts & Recordings: markdown card with a link to https://frigate.$SERVICES_DOMAIN
                      (opens in a new tab, same Authelia session - no extra
                      login; links in the markdown card are target=_blank) plus
                      a pointer to the in-HA media browser.

Alerts and recordings are browsable in HA without leaving HA via the
Frigate integration's media browser (Media > Frigate > Alerts/Recordings/
Clips/Snapshots).

Note: an iframe embed of the Frigate UI does NOT work - cross-origin
iframes do not carry the Authelia session cookie, and Authelia's login
redirect sets X-Frame-Options: DENY (ERR_BLOCKED_BY_RESPONSE).

Dashboard YAML lives in targets/srv0/k3s/homeassistant/dashboards.yaml
(ConfigMap, read-only at /config/dashboards/frigate.yaml).

Gotcha: do NOT add the removed Advanced Camera Card (dermotduffy) via the
UI editor - it is no longer installed (legacy installs are cleaned up by
the homeassistant integration-update init container). For a manual live
view card on storage dashboards, use the core picture-entity card with
entity: camera.rpi, camera_view: live.

Mobile gotcha: the HA companion app caches the frontend in its WebView
(index.html + a service worker). After card install-path changes it may
keep serving a stale frontend without the card import. Fix: clear the
app's storage (Android: app info > Storage > Clear storage) and log in
again - or uninstall/reinstall the app.

Recordings are written over NFS to srv0's $SECONDARY_STORAGE_PATH/frigate
(NFS kept deliberately so the pod can move nodes; it runs on srv0 with the
OpenVINO detector on the Iris Xe iGPU).

Maintenance notes:
- If the rpi go2rtc password ever regenerates (password file deleted),
  update FRIGATE_RTSP_PASSWORD in secrets/VARS.srv0.env and re-apply:
  task srv0:k3s:deploy -- frigate apply
- The Frigate integration self-updates on every Home Assistant pod start
  (checks the latest GitHub release; marker at
  /config/custom_components/frigate/.installed-version).
====================================================================
EOF
