#!/bin/bash
# Render the srv0 apps chart under each GPU_PROFILE and assert the expected
# images/resources. Runs without a cluster; used by CI and before a hardware
# swap to prove both the Intel and AMD paths template cleanly.
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CHART="$INFRA_ROOT/targets/srv0/k3s-apps"
BASE_VALUES="$CHART/values.yaml"
CONFIG_TEMPLATE="$INFRA_ROOT/targets/srv0/config_template/values.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {
    profile="$1"
    out="$2"
    shift 2
    helm template srv0-apps "$CHART" -n apps \
        -f "$BASE_VALUES" -f "$CONFIG_TEMPLATE" \
        --set "GPU_PROFILE=$profile" "$@" >"$out"
    if grep -q '<no value>' "$out"; then
        echo "FAIL: $profile rendered a missing value" >&2
        exit 1
    fi
}

assert_has() { grep -q -- "$2" "$1" || { echo "FAIL: $1 missing '$2'" >&2; exit 1; }; }
assert_not() { ! grep -q -- "$2" "$1" || { echo "FAIL: $1 has unexpected '$2'" >&2; exit 1; }; }
assert_line() { grep -qE -- "(^|[[:space:]])$2$" "$1" || { echo "FAIL: $1 missing line ending '$2'" >&2; exit 1; }; }
assert_not_line() { ! grep -qE -- "(^|[[:space:]])$2$" "$1" || { echo "FAIL: $1 has unexpected line '$2'" >&2; exit 1; }; }
assert_image() { assert_line "$1" "image: $2"; }

# Derive the expected versions from the chart templates. Renovate owns the pins;
# this test owns profile selection, so a version bump must not require editing
# it, and a server-only or ML-only Renovate branch must not fail on a stale pin.
chart_tags() {
    awk -v repo="$2" '
        index($0, "repository: " repo) { inrepo = 1; next }
        inrepo && $1 == "tag:" { gsub(/"/, "", $2); print $2; inrepo = 0 }
    ' "$1"
}

chart_image_tags() {
    awk -v repo="$2" '
        {
            needle = "image: " repo ":"
            pos = index($0, needle)
            if (pos) {
                tag = substr($0, pos + length(needle))
                sub(/[[:space:]].*$/, "", tag)
                print tag
            }
        }
    ' "$1"
}

immich_ml_tags="$(chart_tags "$CHART/templates/immich.yaml" ghcr.io/immich-app/immich-machine-learning)"
immich_ml_base="$(printf '%s\n' "$immich_ml_tags" | grep -vE -- '(-openvino|-rocm)$' | head -n1)"
if [ -z "$immich_ml_base" ]; then
    echo "FAIL: immich.yaml has no plain machine-learning tag" >&2
    exit 1
fi
for v in "$immich_ml_base" "${immich_ml_base}-openvino" "${immich_ml_base}-rocm"; do
    printf '%s\n' "$immich_ml_tags" | grep -qx -- "$v" ||
        { echo "FAIL: immich.yaml missing machine-learning tag '$v'" >&2; exit 1; }
done

frigate_tags="$(chart_image_tags "$CHART/templates/frigate.yaml" ghcr.io/blakeblackshear/frigate)"
frigate_base="$(printf '%s\n' "$frigate_tags" | grep -vE -- '-rocm$' | head -n1)"
if [ -z "$frigate_base" ]; then
    echo "FAIL: frigate.yaml has no plain image tag" >&2
    exit 1
fi
printf '%s\n' "$frigate_tags" | grep -qx -- "${frigate_base}-rocm" ||
    { echo "FAIL: frigate.yaml missing image tag '${frigate_base}-rocm'" >&2; exit 1; }

render intel "$tmp/intel.yaml"
assert_has "$tmp/intel.yaml" "infra.local/intel-gpu"
assert_line "$tmp/intel.yaml" "tag: ${immich_ml_base}-openvino"
assert_has "$tmp/intel.yaml" "infra.local/vaapi"
assert_has "$tmp/intel.yaml" "infra.local/amd-dgpu"   # llama.cpp on bigpc
assert_has "$tmp/intel.yaml" "image: ghcr.io/ggml-org/llama.cpp:server-rocm"
assert_has "$tmp/intel.yaml" "models.home.example.org"
assert_has "$tmp/intel.yaml" "LLAMA_CACHE"
assert_has "$tmp/intel.yaml" '"--fit"'
assert_not "$tmp/intel.yaml" '"--models-preset"'
assert_not "$tmp/intel.yaml" "hf-file"
assert_image "$tmp/intel.yaml" "ghcr.io/blakeblackshear/frigate:${frigate_base}"
assert_not_line "$tmp/intel.yaml" "image: ghcr.io/blakeblackshear/frigate:${frigate_base}-rocm"
assert_not_line "$tmp/intel.yaml" "tag: ${immich_ml_base}-rocm"
assert_not "$tmp/intel.yaml" "name: ensure-model"
assert_has "$tmp/intel.yaml" "infra.local/noschedule"
assert_not "$tmp/intel.yaml" "scheduling-discouraged"

render amd "$tmp/amd.yaml"
assert_image "$tmp/amd.yaml" "ghcr.io/blakeblackshear/frigate:${frigate_base}-rocm"
assert_line "$tmp/amd.yaml" "tag: ${immich_ml_base}-rocm"
assert_has "$tmp/amd.yaml" "infra.local/amd-igpu"
assert_has "$tmp/amd.yaml" "infra.local/amd-dgpu"
assert_has "$tmp/amd.yaml" "image: ghcr.io/ggml-org/llama.cpp:server-rocm"
assert_has "$tmp/amd.yaml" "models.home.example.org"
assert_has "$tmp/amd.yaml" "LLAMA_CACHE"
assert_has "$tmp/amd.yaml" '"--fit"'
assert_not "$tmp/amd.yaml" '"--models-preset"'
assert_not "$tmp/amd.yaml" "hf-file"
assert_has "$tmp/amd.yaml" "infra.local/vaapi"
assert_not "$tmp/amd.yaml" "infra.local/intel-gpu"
# The ROCm detector requires the NCHW float32 yolo-generic model config plus
# the initContainer that seeds the ONNX artifact into the config PVC.
assert_has "$tmp/amd.yaml" "model_type: yolo-generic"
assert_has "$tmp/amd.yaml" "input_tensor: nchw"
assert_has "$tmp/amd.yaml" "input_dtype: float"
assert_has "$tmp/amd.yaml" "name: ensure-model"
assert_has "$tmp/amd.yaml" "yolov9-t-320.onnx"
assert_has "$tmp/amd.yaml" "infra.local/noschedule"
assert_not "$tmp/amd.yaml" "scheduling-discouraged"

render none "$tmp/none.yaml"
assert_image "$tmp/none.yaml" "ghcr.io/blakeblackshear/frigate:${frigate_base}"
assert_line "$tmp/none.yaml" "tag: ${immich_ml_base}"
# llama.cpp has a CPU image for the no-GPU profile.
assert_has "$tmp/none.yaml" "image: ghcr.io/ggml-org/llama.cpp:server@"
assert_not "$tmp/none.yaml" "server-rocm"
assert_has "$tmp/none.yaml" "models.home.example.org"
assert_has "$tmp/none.yaml" "LLAMA_CACHE"
assert_not "$tmp/none.yaml" '"--models-preset"'
assert_not "$tmp/none.yaml" "hf-file"
assert_not "$tmp/none.yaml" "infra.local/vaapi"
assert_not "$tmp/none.yaml" "infra.local/intel-gpu"
assert_has "$tmp/none.yaml" "infra.local/noschedule"
assert_not "$tmp/none.yaml" "scheduling-discouraged"
assert_not "$tmp/none.yaml" "name: ensure-model"

render intel "$tmp/no-hw.yaml" --set HA_CONBEE=false --set HA_BLUETOOTH=false
assert_not "$tmp/no-hw.yaml" "infra.local/conbee"
assert_not "$tmp/no-hw.yaml" "usb-serial"
assert_not "$tmp/no-hw.yaml" "run/dbus/system_bus_socket"

echo "gpu profile renders: OK"
