# Runbook: srv0 motherboard swap (Intel Iris Xe → AMD 780M)

This runbook moves the Framework 13 AMD Ryzen 7 7840U mainboard (currently
`pc`) into `srv0`, and the Framework 12th Gen Intel i5-1240P mainboard
(currently `srv0`) into `pc`. `bigpc` is unchanged.

## Target topology

| Node | Before | After | Accelerator |
|---|---|---|---|
| `srv0` | Framework 12th Gen i5-1240P, Iris Xe | Framework 13 AMD 7840U, Radeon 780M | `amd-igpu` + `vaapi` |
| `pc` | Framework 13 AMD 7840U, Radeon 780M | Framework 12th Gen i5-1240P, Iris Xe | Compose only |
| `bigpc` | RX 9070 16 GiB + Radeon 610M | unchanged | `amd-dgpu` + `amd-igpu` + `vaapi` |

## 1. Pre-flight

- Take a fresh restic backup and a K3s etcd snapshot; record `helm get values`
  for `srv0-base` and `srv0-apps`.
- Record the current inventory:
  ```bash
  hostname; lscpu; free -h
  lspci -nnk | grep -A3 -E 'VGA|Display|3D'
  lsblk -o NAME,SIZE,TRAN,TYPE,MODEL,MOUNTPOINTS
  ip -br link
  lsusb
  ```
- Confirm the physical mapping **before** disassembly:
  - **RAM moves with the mainboard.** Framework 12th Gen uses DDR4 SO-DIMMs;
    Framework 13 AMD uses DDR5 SO-DIMMs. They are not interchangeable.
  - **OS disks must match their roles.** Move srv0's 4 TB LUKS NVMe into the
    AMD mainboard, and pc's Viper 4 TB NVMe into the Intel mainboard. Do not
    boot the server OS on the desktop board or vice versa.
  - Move srv0's USB SSD (`k3s_extra_storage`), USB 2.5 G Ethernet adapter,
    ConBee II, and a USB-A expansion card/hub to the AMD mainboard. The AMD
    mainboard has USB-C ports; the ConBee and USB SSD need a USB-A path.
  - pc keeps its own peripherals and gets the Intel mainboard with its DDR4
    RAM. Its AX210 Wi-Fi/Bluetooth moves with the Intel mainboard.
- Confirm `amd-ucode-firmware` is installed on srv0 (it is today). The Intel
  board's `intel-ucode-firmware` is not needed on srv0 after the swap.
- Verify the initramfs has the USB NIC/storage modules (run on srv0):
  ```bash
  lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'r8152|xhci_pci|usb-storage|uas|nvme'
  ```
  If `r8152`/`xhci_pci` are absent, rebuild with `sudo dracut -f` and re-run
  `bash scripts/preboot.sh public-exposure` **before** the swap. The initramfs
  WireGuard unlock depends on the USB Ethernet adapter.
- Have a USB-C display and keyboard available for the first boot in case the
  initramfs cannot bring up the USB NIC.

## 2. Physical swap

1. Power off both machines and unplug AC.
2. Remove the NVMe, RAM, Wi-Fi card, and expansion cards with each mainboard.
3. Install the AMD mainboard in the srv0 chassis with srv0's DDR5 RAM, server
   NVMe, USB SSD, USB Ethernet, ConBee, and USB-A expansion card.
4. Install the Intel mainboard in the pc chassis with pc's DDR4 RAM, pc NVMe,
   and AX210 card.
5. Reconnect cooling, power, and antennas. The AMD mainboard's MT7922
   Wi-Fi/Bluetooth is only useful if its antennas are connected; the server
   does not use Wi-Fi, but Home Assistant Bluetooth does.
6. Set "power on after AC loss" in the AMD BIOS if available.

## 3. First boot and LUKS

- Watch the LUKS prompt. If remote unlock does not come up, use the local
  display/keyboard.
- After unlock and boot:
  ```bash
  ip -br link
  ip -4 addr show
  systemctl status k3s
  kubectl get nodes -o wide
  ```
- Confirm the server's reserved LAN address and that the USB Ethernet adapter
  kept its MAC. Wi-Fi is not used.
- If the initramfs needed changes, rebuild it now:
  ```bash
  sudo dracut -f
  bash scripts/preboot.sh public-exposure
  ```
  and test one reboot before considering the swap complete.

## 4. Verify the new hardware resources

Run the generator directly first (no cluster changes):

```bash
cd /home/imranr/Main/Infra
SYSFS_ROOT=/sys DEV_ROOT=/dev OUTPUT=/tmp/gdp-srv0.yaml \
  sh targets/srv0/k3s-base/files/generic-device-plugin-init.sh
cat /tmp/gdp-srv0.yaml
```

Expected on srv0 after the swap: `amd-igpu`, `vaapi`; **no** `intel-gpu`.
Expected on bigpc: `amd-dgpu`, `amd-igpu`, `vaapi`.

Then roll the plugin and inspect allocatable:

```bash
kubectl -n base rollout restart ds/generic-device-plugin
kubectl -n base rollout status ds/generic-device-plugin
kubectl get node srv0 -o json | yq '.status.allocatable | with_entries(select(.key | test("^infra\\.")))'
kubectl get node bigpc -o json | yq '.status.allocatable | with_entries(select(.key | test("^infra\\.")))'
```

## 5. Accelerator cutover

Before the swap, the deployment uses:

```yaml
GPU_PROFILE: "intel"
```

After the AMD mainboard is in srv0 and `amd-igpu`/`vaapi` are advertised, set:

```yaml
GPU_PROFILE: "amd"
```

in `config/srv0/values.yaml`, then:

```bash
bash scripts/validate.sh srv0
bash scripts/deploy.sh srv0
```

Expected result:

- Frigate: `frigate:0.18.2-rocm`, ONNX detector on the 780M, VAAPI decode.
- Immich ML: `v3.3.5-rocm` on bigpc's RX 9070 (`amd-dgpu`), or CPU if
  `IMMICH_ML_BACKEND=cpu`.
- Immich server and Jellyfin: `vaapi` on the 780M.
- Ollama: `amd-dgpu` on bigpc's RX 9070.
- Home Assistant: ConBee by-id and MT7922 Bluetooth (or set
  `HA_BLUETOOTH=false` if the antenna/adapter is not usable).

### Frigate ONNX model

The ROCm detector needs `/config/model_cache/yolov9-t-320.onnx`. The chart
provisions it automatically: the `ensure-model` initContainer fetches
`FRIGATE_MODEL_URL` into the frigate-config PVC and verifies
`FRIGATE_MODEL_SHA256` before Frigate starts. No manual `kubectl cp` is needed,
and a fresh or restored PVC is seeded on the next pod start.

The exported model is NCHW float32, so the chart sets
`model_type: yolo-generic`, `input_tensor: nchw`, and `input_dtype: float`.
The label map (`/labelmap/coco-80.txt`) ships inside the Frigate image.

To rebuild the artifact (for example after a Frigate model-format change):

```bash
mkdir -p /tmp/yolov9-build/out && cd /tmp/yolov9-build
podman build --build-arg MODEL_SIZE=t --build-arg IMG_SIZE=320 \
  -o type=local,dest=out -f- <<'EOF'
# Paste the Dockerfile from the Frigate object-detector docs, "Download the
# model" section (python:3.11 build stage + FROM scratch output stage).
EOF
```

Verify the graph is a float32 NCHW 320x320 input with an `[1, 84, 2100]`
output, then commit the file and its digest together:

```bash
install -m 644 out/yolov9-t-320.onnx "$INFRA_ROOT/targets/srv0/assets/yolov9-t-320.onnx"
sha256sum "$INFRA_ROOT/targets/srv0/assets/yolov9-t-320.onnx"
```

Put the new digest in `targets/srv0/k3s-apps/values.yaml`
(`FRIGATE_MODEL_SHA256`). The next pod start re-fetches the model and
replaces the old file.

## 6. Fallbacks

- Frigate ROCm fails on the 780M: set `FRIGATE_GPU_RESOURCE=amd-dgpu` to run it
  on bigpc's RX 9070, or `FRIGATE_DETECTOR=cpu`.
- Immich ML ROCm fails: set `IMMICH_ML_BACKEND=cpu`.
- Jellyfin VAAPI fails: `JELLYFIN_HWACCEL=none`.
- Immich server VAAPI fails: `IMMICH_SERVER_HWACCEL=none`.
- Home Assistant Bluetooth is unusable: `HA_BLUETOOTH=false`.
- No GPU at all: `GPU_PROFILE=none`.

## 7. Rollback

- Keep the Intel mainboard and its DDR4 RAM intact until srv0 has booted,
  unlocked, joined K3s, and run the media/ML workloads successfully.
- Helm revisions are retained; `GPU_PROFILE=none` is the quickest software
  rollback if the AMD GPU path is not ready.
- If the AMD mainboard cannot boot the server NVMe, swap the mainboards back
  before changing any cluster state; the OS disk and K3s data are unchanged.
