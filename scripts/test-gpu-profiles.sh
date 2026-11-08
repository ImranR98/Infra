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

render intel "$tmp/intel.yaml"
assert_has "$tmp/intel.yaml" "infra.local/intel-gpu"
assert_has "$tmp/intel.yaml" "tag: v3.3.5-openvino"
assert_has "$tmp/intel.yaml" "infra.local/vaapi"
assert_has "$tmp/intel.yaml" "infra.local/amd-dgpu"   # llama.cpp on bigpc
assert_has "$tmp/intel.yaml" "image: ghcr.io/ggml-org/llama.cpp:server-rocm"
assert_has "$tmp/intel.yaml" "models.home.example.org"
assert_has "$tmp/intel.yaml" "LLAMA_CACHE"
assert_has "$tmp/intel.yaml" '"--fit"'
assert_not "$tmp/intel.yaml" '"--models-preset"'
assert_not "$tmp/intel.yaml" "hf-file"
assert_not "$tmp/intel.yaml" "frigate:0.18.2-rocm"
assert_not "$tmp/intel.yaml" "tag: v3.3.5-rocm"
assert_not "$tmp/intel.yaml" "name: ensure-model"
assert_has "$tmp/intel.yaml" "yanwk/comfyui-boot:rocm"
assert_has "$tmp/intel.yaml" "name: comfyui"
assert_has "$tmp/intel.yaml" "infra.local/noschedule"
assert_not "$tmp/intel.yaml" "scheduling-discouraged"

render amd "$tmp/amd.yaml"
assert_has "$tmp/amd.yaml" "ghcr.io/blakeblackshear/frigate:0.18.2-rocm"
assert_has "$tmp/amd.yaml" "tag: v3.3.5-rocm"
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
assert_has "$tmp/amd.yaml" "yanwk/comfyui-boot:rocm"
assert_has "$tmp/amd.yaml" "name: comfyui"
assert_has "$tmp/amd.yaml" "infra.local/noschedule"
assert_not "$tmp/amd.yaml" "scheduling-discouraged"

render none "$tmp/none.yaml"
assert_has "$tmp/none.yaml" "ghcr.io/blakeblackshear/frigate:0.18.2"
# llama.cpp has a CPU image for the no-GPU profile.
assert_has "$tmp/none.yaml" "image: ghcr.io/ggml-org/llama.cpp:server@"
assert_not "$tmp/none.yaml" "server-rocm"
assert_has "$tmp/none.yaml" "models.home.example.org"
assert_has "$tmp/none.yaml" "LLAMA_CACHE"
assert_not "$tmp/none.yaml" '"--models-preset"'
assert_not "$tmp/none.yaml" "hf-file"
assert_not "$tmp/none.yaml" "infra.local/vaapi"
assert_not "$tmp/none.yaml" "infra.local/intel-gpu"
# ComfyUI is independent of GPU_PROFILE and always requests the bigpc dGPU.
assert_has "$tmp/none.yaml" "yanwk/comfyui-boot:rocm"
assert_has "$tmp/none.yaml" "name: comfyui"
assert_has "$tmp/none.yaml" 'infra.local/amd-dgpu: "1"'
assert_has "$tmp/none.yaml" "infra.local/noschedule"
assert_not "$tmp/none.yaml" "scheduling-discouraged"
assert_not "$tmp/none.yaml" "name: ensure-model"

render intel "$tmp/no-hw.yaml" --set HA_CONBEE=false --set HA_BLUETOOTH=false
assert_not "$tmp/no-hw.yaml" "infra.local/conbee"
assert_not "$tmp/no-hw.yaml" "usb-serial"
assert_not "$tmp/no-hw.yaml" "run/dbus/system_bus_socket"

echo "gpu profile renders: OK"
