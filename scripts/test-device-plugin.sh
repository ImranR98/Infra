#!/bin/bash
# Fixture tests for targets/srv0/k3s-base/files/generic-device-plugin-init.sh.
# Runs without a cluster or real hardware; verifies resource discovery,
# AMD iGPU/dGPU classification, VAAPI preference, and ConBee by-id handling.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GENERATOR="$INFRA_ROOT/targets/srv0/k3s-base/files/generic-device-plugin-init.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_has() {
    grep -q -- "$2" "$1" || fail "missing '$2' in $1"
}

assert_not() {
    ! grep -q -- "$2" "$1" || fail "unexpected '$2' in $1"
}

make_root() {
    root="$tmp/$1"
    rm -rf "$root"
    mkdir -p "$root/sys/bus/pci/drivers/i915" \
        "$root/sys/bus/pci/drivers/xe" \
        "$root/sys/bus/pci/drivers/amdgpu" \
        "$root/dev/dri" \
        "$root/dev/serial/by-id"
    printf '%s\n' "$root"
}

add_gpu() {
    root="$1"
    card="$2"
    render="$3"
    driver="$4"
    vram="$5"
    dev="$root/sys/devices/pci0000:00/$render"

    mkdir -p "$dev" "$root/sys/class/drm/$card" "$root/sys/class/drm/$render"
    ln -s "$root/sys/bus/pci/drivers/$driver" "$dev/driver"
    ln -s "$dev" "$root/sys/class/drm/$card/device"
    ln -s "$dev" "$root/sys/class/drm/$render/device"
    [ -z "$vram" ] || printf '%s' "$vram" >"$dev/mem_info_vram_total"
    : >"$root/dev/dri/$render"
}

run_generator() {
    root="$1"
    out="$root/out/config.yaml"
    mkdir -p "$root/out"
    OUTPUT="$out" SYSFS_ROOT="$root/sys" DEV_ROOT="$root/dev" \
        sh "$GENERATOR"
    printf '%s\n' "$out"
}

# Intel iGPU: OpenVINO + VAAPI, no AMD resources.
intel_root="$(make_root intel)"
add_gpu "$intel_root" card0 renderD128 i915 ""
intel_out="$(run_generator "$intel_root")"
assert_has "$intel_out" "name: intel-gpu"
assert_has "$intel_out" "name: vaapi"
assert_not "$intel_out" "name: amd-"
assert_not "$intel_out" "name: conbee"

# AMD dGPU + iGPU: both ROCm resources, VAAPI prefers the dGPU, ConBee by-id.
amd_root="$(make_root amd)"
: >"$amd_root/dev/kfd"
add_gpu "$amd_root" card1 renderD128 amdgpu 17095983104
add_gpu "$amd_root" card0 renderD129 amdgpu 536870912
: >"$amd_root/dev/ttyACM0"
ln -s "$amd_root/dev/ttyACM0" \
    "$amd_root/dev/serial/by-id/usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_DE2285507-if00"
amd_out="$(run_generator "$amd_root")"
assert_has "$amd_out" "name: amd-dgpu"
assert_has "$amd_out" "name: amd-igpu"
assert_has "$amd_out" "name: vaapi"
assert_has "$amd_out" "name: conbee"
assert_has "$amd_out" "mountPath: /dev/dri/renderD128"
assert_not "$amd_out" "mountPath: /dev/dri/renderD129"
assert_not "$amd_out" "name: intel-gpu"

# No devices: valid empty config.
empty_root="$(make_root empty)"
rmdir "$empty_root/dev/serial/by-id"
empty_out="$(run_generator "$empty_root")"
assert_has "$empty_out" "device: \[\]"

echo "device-plugin fixtures: OK"
