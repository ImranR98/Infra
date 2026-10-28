#!/bin/sh
# Generate the per-node generic-device-plugin config from sysfs and /dev.
#
# Resources are capabilities, not node labels:
#   infra.local/vaapi     - one VAAPI render node, preferring a discrete GPU
#   infra.local/intel-gpu - i915/xe render node (OpenVINO)
#   infra.local/amd-igpu  - AMD integrated GPU (kfd + DRM nodes, ROCm)
#   infra.local/amd-dgpu  - AMD discrete GPU (kfd + DRM nodes, ROCm)
#   infra.local/conbee    - ConBee II, found by /dev/serial/by-id
#
# Device paths are normalized to stable in-container names (card0,
# renderD128, ttyACM0) so app config never depends on host enumeration order.
# The paths are discovered at plugin startup; a hardware change only requires
# a DaemonSet rollout (the chart checksum rolls it when this script changes).
set -eu

SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
DEV_ROOT="${DEV_ROOT:-/dev}"
OUTPUT="${OUTPUT:-/etc/generic-device-plugin/config.yaml}"
# 4 GiB separates current APU carveouts (512 MiB) from discrete cards (16 GiB).
DGPU_VRAM_MIN="${DGPU_VRAM_MIN:-4294967296}"

tmp="${OUTPUT}.tmp"
renders="${OUTPUT}.renders"
group_count=0

cleanup() {
    rm -f "$tmp" "$renders"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$(dirname "$OUTPUT")"
: >"$renders"
printf 'device:\n' >"$tmp"

# emit_group <name> <count> <src|dst>...
emit_group() {
    name="$1"
    count="$2"
    shift 2
    group_count=$((group_count + 1))
    printf '  - name: %s\n    groups:\n      - count: %s\n        paths:\n' "$name" "$count" >>"$tmp"
    for spec in "$@"; do
        src="${spec%%|*}"
        dst="${spec#*|}"
        printf '          - path: %s\n' "$src" >>"$tmp"
        [ -z "$dst" ] || printf '            mountPath: %s\n' "$dst" >>"$tmp"
    done
}

# Discover render nodes and the card node that shares the same parent device.
for render_sys in "$SYSFS_ROOT"/class/drm/renderD*; do
    [ -e "$render_sys" ] || continue
    [ -e "$render_sys/device/driver" ] || continue
    render="$(basename "$render_sys")"
    driver="$(basename "$(readlink -f "$render_sys/device/driver")")"
    [ -e "$DEV_ROOT/dri/$render" ] || continue

    card=""
    for card_sys in "$SYSFS_ROOT"/class/drm/card[0-9]*; do
        [ -e "$card_sys/device" ] || continue
        case "$(basename "$card_sys")" in
            card[0-9] | card[0-9][0-9]) ;;
            *) continue ;;
        esac
        if [ "$(readlink -f "$card_sys/device")" = "$(readlink -f "$render_sys/device")" ]; then
            card="$(basename "$card_sys")"
            break
        fi
    done

    vram=""
    if [ -r "$render_sys/device/mem_info_vram_total" ]; then
        vram="$(cat "$render_sys/device/mem_info_vram_total")"
    fi
    case "$vram" in
        '' | *[!0-9]*) vram=0 ;;
    esac

    case "$driver" in
        i915 | xe) class=intel ;;
        amdgpu)
            if [ "$vram" -gt "$DGPU_VRAM_MIN" ]; then
                class=amd-dgpu
            else
                class=amd-igpu
            fi
            ;;
        *) class=other ;;
    esac

    printf '%s|%s|%s|%s|%s\n' "$render" "$driver" "$class" "$card" "$vram" >>"$renders"
done

has_intel=0
has_amd_igpu=0
has_amd_dgpu=0
while IFS='|' read -r render driver class card vram; do
    case "$class" in
        intel) has_intel=1 ;;
        amd-igpu) has_amd_igpu=1 ;;
        amd-dgpu) has_amd_dgpu=1 ;;
    esac
done <"$renders"

# Intel iGPU/Arc: OpenVINO uses the render node directly.
while IFS='|' read -r render driver class card vram; do
    [ "$class" = intel ] || continue
    emit_group intel-gpu 32 "$DEV_ROOT/dri/$render|/dev/dri/renderD128"
done <"$renders"

# AMD ROCm: kfd is shared, but the card/render pair identifies the selected GPU.
if [ -e "$DEV_ROOT/kfd" ]; then
    while IFS='|' read -r render driver class card vram; do
        case "$class" in
            amd-igpu | amd-dgpu) ;;
            *) continue ;;
        esac
        [ -n "$card" ] || continue
        emit_group "$class" 32 \
            "$DEV_ROOT/kfd|/dev/kfd" \
            "$DEV_ROOT/dri/$card|/dev/dri/card0" \
            "$DEV_ROOT/dri/$render|/dev/dri/renderD128"
    done <"$renders"
fi

# VAAPI: prefer a discrete GPU; otherwise the integrated one. Intel and AMD
# both expose a render node, so consumers can use one vendor-neutral resource.
vaapi_class=""
if [ "$has_amd_dgpu" = 1 ]; then
    vaapi_class=amd-dgpu
elif [ "$has_amd_igpu" = 1 ]; then
    vaapi_class=amd-igpu
elif [ "$has_intel" = 1 ]; then
    vaapi_class=intel
fi
if [ -n "$vaapi_class" ]; then
    while IFS='|' read -r render driver class card vram; do
        [ "$class" = "$vaapi_class" ] || continue
        emit_group vaapi 32 "$DEV_ROOT/dri/$render|/dev/dri/renderD128"
    done <"$renders"
fi

# ConBee II: discover by-id so ttyACM renumbering (or a USB port change) does
# not change the resource. The container path is normalized to ttyACM0.
for byid in "$DEV_ROOT"/serial/by-id/*ConBee*; do
    [ -e "$byid" ] || continue
    emit_group conbee 32 "$byid|/dev/ttyACM0"
done

if [ "$group_count" -eq 0 ]; then
    printf 'device: []\n' >"$tmp"
fi

mv "$tmp" "$OUTPUT"
rm -f "$renders"
trap - EXIT HUP INT TERM
