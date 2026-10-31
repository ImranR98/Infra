# Frigate model artifacts

`yolov9-t-320.onnx` is the YOLOv9-t model exported at 320x320 for the Frigate
ROCm/ONNX detector.

- Source weights: <https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-t-converted.pt>
- Recipe: the Dockerfile in the Frigate object-detector docs ("Download the
  model"), built with `MODEL_SIZE=t` and `IMG_SIZE=320`.
- Graph: input `float32` NCHW `[1, 3, 320, 320]` (`images`), output `float32`
  `[1, 84, 2100]` (`output0`), IR 10 / opset 18.
- SHA-256: `1faaa8baafd9b9075f700e589701ca004f2d9fb98b2138fb2d778607a7783fbb`

The file lives outside the Helm chart so the release Secret stays below the
1 MiB limit. The `ensure-model` initContainer in
`targets/srv0/k3s-apps/templates/frigate.yaml` fetches it into the
frigate-config PVC and verifies the digest before Frigate starts. Rebuild
instructions are in [docs/runbooks/hardware-swap.md](../../../docs/runbooks/hardware-swap.md).
