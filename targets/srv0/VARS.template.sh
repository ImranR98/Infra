# ====== Domain ======
export SERVICES_DOMAIN="home.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"
export TZ="America/Toronto"

# ====== Ntfy ======
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16
export NTFY_ADMIN_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash
export NTFY_WRITE_ONLY_ACCOUNT_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash

# ====== Geoblock (Traefik middleware) ======
# Indentation matters — must match spec.plugin.geoblock level in middlewares.yaml (6 spaces).
export GEOBLOCK_CONFIG_SUBSET='
      blackListMode: false
      countries:
        - CA
        - CN
        - CU
'

# ====== GeoIP (self-hosted MaxMind GeoLite2) ======
# Register at https://www.maxmind.com and generate a GeoLite2 license key
export GEOIPUPDATE_ACCOUNT_ID="change_me"
export GEOIPUPDATE_LICENSE_KEY="change_me"

# ====== Host Paths ======
# Ensure these exist before starting services
export MAIN_PARENT_DIR="/path/to/data"
export MEDIA_DIR_PATH="$MAIN_PARENT_DIR/Main/Media"
export DSCPLN_TRANSACTIONS_PATH="$MAIN_PARENT_DIR/Main/Notes/Transactions"
export MDSCL_DEVICE_SYNC_PATH="$MAIN_PARENT_DIR/deviceSync"
export SECONDARY_STORAGE_PATH="/mnt/k3s_extra_storage"

# ====== Authelia ======
# Use `docker run -it authelia/authelia:latest authelia crypto hash generate argon2` to generate the password hash
# Indentation matters: needs 2 spaces more than the 4-space block scalar base (6/8/10 spaces)
# For one-time 2FA registration: kubectl -n base exec -it "$(kubectl -n base get pod | grep -E '^authelia' | grep -Ev '(postgres|redis)' | awk '{print $1}')" -- cat /notifications/notification.txt
export AUTHELIA_USERS_DATABASE="users:
      admin:
        disabled: false
        displayname: \"Admin\"
        password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\"
        email: $DOMAIN_OWNER_EMAIL
        groups:
          - admins"
export AUTHELIA_DB_ENCRYPTION_KEY="change_me" # openssl rand -hex 128
export AUTHELIA_JWT_SECRET="change_me" # openssl rand -hex 128
export AUTHELIA_OIDC_HMAC_SECRET="change_me" # openssl rand -hex 128
export AUTHELIA_REDIS_PASSWORD="change_me" # openssl rand -base64 32
export AUTHELIA_DB_PASSWORD="change_me" # openssl rand -base64 32
# openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | base64 | tr -d '\n'
# Indentation matters
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
                  change_me
                  -----END PRIVATE KEY-----"
export AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_OPENWEBUI_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_HEADLAMP_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_LINKWARDEN_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986

# ====== Authelia header gate ======
# Set to "true" to force the gate on (blocking all requests without a valid
# Authelia session). Auto-enabled on first deploy; leave "false" otherwise.
export AUTHELIA_HEADER_GATE_ENABLED="false"

# ====== Crowdsec ======
export CROWDSEC_BOUNCER_KEY="change_me" # openssl rand -hex 32
export CROWDSEC_LAPI_SECRET="change_me" # openssl rand -hex 32

# ====== Localhost Basic Auth ======
export LOCALHOST_AUTH_USER="admin"
export LOCALHOST_AUTH_PASSWORD_HASH="change_me" # openssl passwd -6 'password'

# ====== Immich ======
export IMMICH_DB_PASSWORD="change_me" # openssl rand -hex 16

# ====== Mosquitto ======
# Format: mosquitto password file lines ("user:hash"), ONE LINE PER ENTRY, each line
# indented with 4 spaces (rendered into a YAML block scalar, like AUTHELIA_USERS_DATABASE).
# IMPORTANT: generate hashes with the SAME mosquitto_passwd version as the runtime
# image (eclipse-mosquitto:2.0.22-openssl). Newer mosquitto_passwd (2.1+) emits
# $7$1000$ hashes that 2.0.x cannot decode ("Unable to decode password salt").
#   tmpfile=$(mktemp) && docker run --rm -v "$tmpfile":/pw eclipse-mosquitto:2.0.22-openssl mosquitto_passwd -b /pw frigate '<FRIGATE_MQTT_PASSWORD>' \
#   && docker run --rm -v "$tmpfile":/pw eclipse-mosquitto:2.0.22-openssl mosquitto_passwd -b /pw homeassistant '<HA_MQTT_PASSWORD>' && cat "$tmpfile"
export MOSQUITTO_CREDENTIALS="change_me" # tmpfile=$(mktemp) && mosquitto_passwd -b "$tmpfile" admin 'your-password' && cat "$tmpfile" && rm "$tmpfile"

# ====== Frigate (NVR) ======
# Password of the rpi go2rtc stream: `docker logs go2rtc` on the Pi, or
# current_target/compose_live_state/go2rtc/password. Update if the Pi password regenerates.
export FRIGATE_RTSP_PASSWORD="change_me"
export RPI_CAM_IP="change_me" # LAN IP of the rpi go2rtc webcam host
export FRIGATE_MQTT_PASSWORD="change_me" # openssl rand -hex 16 (also add `frigate` user to MOSQUITTO_CREDENTIALS)
export HA_MQTT_PASSWORD="change_me" # openssl rand -hex 16 (also add `homeassistant` user to MOSQUITTO_CREDENTIALS)
# Deployment-specific Frigate config (go2rtc streams, cameras) appended to the
# hardcoded section in frigate/helmchart.yaml (envsubst before kustomize).
# Multi-line YAML: the template line provides 6 spaces, so every line is indented
# 6 + target-indent (the config block strips 6). {FRIGATE_*} tokens are
# substituted by Frigate at runtime.
# GUI config-editor changes don't survive restarts - scrape them back into here.
export FRIGATE_ADDITIONAL_CONFIG="go2rtc:
        streams:
          rpi: rtsp://admin:{FRIGATE_RTSP_PASSWORD}@$RPI_CAM_IP:8554/rpi#timeout=5
      cameras:
        # Default camera: rpi go2rtc webcam stream (targets/rpi)
        rpi:
          ffmpeg:
            inputs:
              - path: rtsp://127.0.0.1:8554/rpi
                roles:
                  - detect
              - path: rtsp://127.0.0.1:8554/rpi
                roles:
                  - record
          detect:
            width: 640
            height: 480
            # Frigate 0.17 defaults detect.enabled to FALSE - pin it ON in the
            # config, otherwise every Frigate restart silently disables
            # detection (and HA mirrors the off state onto switch.rpi_detect).
            enabled: true
            # Detection-only fps (motion + object detection). Does NOT affect
            # the record-role input or the go2rtc livestream - those are
            # separate pipelines.
            fps: 5
          motion:
            # Low-light webcam noise fix: improve_contrast stretches the
            # near-black sensor noise at night into full-range "changes",
            # producing continuous false motion (hour-long recordings).
            # Disabling it keeps noise below the motion threshold.
            improve_contrast: false
            # 1.0 disables the lightning recalibration: without it, a person
            # filling the webcam frame (>80% change) is treated as "lightning"
            # and motion detection recalibrates, swallowing the event
            # (Frigate docs: doorbell camera scenario).
            lightning_threshold: 1.0
          record:
            enabled: true
            motion:
              # Keep segments that contain motion even when no object is
              # tracked (otherwise motion-only activity has no recording).
              days: 14
            alerts:
              retain:
                days: 14
                # Keep segments with actively tracked objects, not only
                # motion (person standing still is still recorded).
                mode: active_objects
            detections:
              retain:
                days: 14
                mode: active_objects
          snapshots:
            enabled: true
        # -------- HOW TO ADD MORE CAMERAS (copy + uncomment a block) --------
        # Example 1: LAN IP camera over RTSP (most common)
        #   doorbell:
        #     ffmpeg:
        #       inputs:
        #         - path: rtsp://user:password@192.168.8.XX:554/stream1
        #           roles:
        #             - detect
        #             - record
        #     detect:
        #       width: 1280
        #       height: 720
        #       fps: 5
        #     record:
        #       enabled: true
        #       detections:
        #         retain:
        #           days: 7
        # Example 2: USB camera plugged into the frigate node itself.
        #   Path is the V4L2 device inside the container (the pod is privileged,
        #   so all /dev/video* nodes of the node are visible).
        #   local_usb:
        #     ffmpeg:
        #       inputs:
        #         - path: /dev/video0
        #           roles:
        #             - detect
        #     detect:
        #       width: 1280
        #       height: 720
        #       fps: 5
        # Example 3: HTTP/MJPEG source (old webcams, some NVRs)
        #   old_cam:
        #     ffmpeg:
        #       inputs:
        #         - path: http://192.168.8.XX/cgi-bin/video.cgi?type=mjpeg
        #           roles:
        #             - detect
        # Example 4: camera behind an exotic source via Frigate's go2rtc
        #   restream - add the source to go2rtc.streams above (e.g.
        #   backyard: rtsp://...), then consume it locally:
        #   backyard:
        #     ffmpeg:
        #       inputs:
        #         - path: rtsp://127.0.0.1:8554/backyard
        #           roles:
        #             - detect
        #             - record
        #     detect:
        #       width: 1280
        #       height: 720
        #       fps: 5"

# ====== FreshRSS ======
export FRESHRSS_PASSWORD="change_me" # openssl rand -base64 32

# ====== Linkwarden ======
# AUTHELIA_LINKWARDEN_CLIENT_SECRET_HASHABLE (above) must be the same random
# password Linkwarden receives as its OIDC client secret.
export LINKWARDEN_NEXTAUTH_SECRET="change_me" # openssl rand -base64 32
export LINKWARDEN_DB_PASSWORD="change_me" # openssl rand -hex 16
export LINKWARDEN_MEILI_MASTER_KEY="change_me" # openssl rand -base64 32
# Links archived in parallel per batch (each spawns Chromium + monolith, ~1-2Gi
# each on big pages). Low = lower peak memory at the cost of bulk-import speed.
export LINKWARDEN_ARCHIVE_TAKE_COUNT="1"

# ====== Plik ======
export PLIK_ADMIN_PASSWORD="change_me" # openssl rand -hex 16

# ====== D$CPLN ======
export DSCPLN_DATA_FILE="Acc $(date +%Y).md"
export DSCPLN_BUDGET_INIT_AMT="2400"
export DSCPLN_FIRST_WEEK_BIAS_INIT_AMT="1400"

# ====== FMD ======
export FMD_REGISTRATIONTOKEN="change_me" # openssl rand -base64 32

# ====== OpenCanary ======
export OPENCANARY_NTFY_SECRET_TOPIC="change_me" # openssl rand -base64 32

# ====== Radarr / Sonarr ======
export RADARR_API_KEY="change_me" # openssl rand -hex 16
export SONARR_API_KEY="change_me" # openssl rand -hex 16

# ====== Prowlarr ======
export PROWLARR_API_KEY="change_me" # openssl rand -hex 16

# ====== Nextcloud ======
export NEXTCLOUD_ADMIN_USER="admin"
export NEXTCLOUD_ADMIN_PASSWORD="change_me" # openssl rand -hex 16
export NEXTCLOUD_DB_PASSWORD="change_me" # openssl rand -hex 16

# ====== Copyparty ======
export COPYPARTY_ADMIN_PASSWORD="changeme" # openssl rand -hex 16

# ====== FRP ======
export PROXY_HOST="vps0.example.org"
export FRPS_PREBOOT_PORT="change_me" # Preboot SSH port; must match the FRP server's preboot port mapping
# Generate with: ./infra.sh srv0 compose generate-mtls-certs vps0
# Use the heredoc pattern below for multi-line PEM data:
export MTLS_CA_CERT="$(cat <<'MTLS_CERT_EOF'
-----BEGIN CERTIFICATE-----
<CA-certificate-pem-block>
-----END CERTIFICATE-----
MTLS_CERT_EOF
)"
export MTLS_CA_KEY="$(cat <<'MTLS_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<CA-private-key-pem-block>
-----END PRIVATE KEY-----
MTLS_CERT_EOF
)"
export MTLS_CLIENT_CERT="$(cat <<'MTLS_CERT_EOF'
-----BEGIN CERTIFICATE-----
<client-certificate-pem-block>
-----END CERTIFICATE-----
MTLS_CERT_EOF
)"
export MTLS_CLIENT_KEY="$(cat <<'MTLS_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<client-private-key-pem-block>
-----END PRIVATE KEY-----
MTLS_CERT_EOF
)"
export MTLS_PREBOOT_CLIENT_CERT="$(cat <<'MTLS_CERT_EOF'
-----BEGIN CERTIFICATE-----
<preboot-client-certificate-pem-block>
-----END CERTIFICATE-----
MTLS_CERT_EOF
)"
export MTLS_PREBOOT_CLIENT_KEY="$(cat <<'MTLS_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<preboot-client-private-key-pem-block>
-----END PRIVATE KEY-----
MTLS_CERT_EOF
)"

# ====== Observability ======
export RUSTFS_ACCESS_KEY="change_me" # openssl rand -hex 16
export RUSTFS_SECRET_KEY="change_me" # openssl rand -hex 32
export GRAFANA_ADMIN_PASSWORD="change_me" # openssl rand -base64 32
# Same convention as the other Authelia OIDC clients: the plaintext secret
# Grafana presents as its OIDC client secret (the _HASHED form is mounted
# into Authelia via authelia/prereqs.yaml).
export AUTHELIA_GRAFANA_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
