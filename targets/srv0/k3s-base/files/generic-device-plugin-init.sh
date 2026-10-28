#!/bin/sh
# Generate the per-node device-plugin config. The base config is shared by
# every node; the Intel iGPU group is appended only where renderD128 is backed
# by the i915 or xe driver (srv0). bigpc's AMD render nodes never get it, so
# `infra.local/intel-gpu` is a real hardware pin rather than a node label.
set -eu

src=/etc/generic-device-plugin-src/config.yaml
dst=/etc/generic-device-plugin/config.yaml

cp "$src" "$dst"

driver=""
if [ -e /sys/class/drm/renderD128/device/driver ]; then
    driver="$(basename "$(readlink /sys/class/drm/renderD128/device/driver)")"
fi

case "$driver" in
    i915|xe)
        printf '\n' >>"$dst"
        cat >>"$dst" <<'EOF'
  - name: intel-gpu
    groups:
      - count: 32
        paths:
          - path: /dev/dri/renderD128
EOF
        ;;
esac
