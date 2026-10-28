{{/*
Resolve accelerator backends. GPU_PROFILE is the deployment-wide default
(intel | amd | none); each app can override its backend/resource explicitly.
The device plugin advertises capabilities, not node labels, so these values
only choose which resource/image the workload consumes.
*/}}
{{- define "gpu.profile" -}}
{{- default "intel" .Values.GPU_PROFILE -}}
{{- end -}}

{{- define "gpu.frigateDetector" -}}
{{- if .Values.FRIGATE_DETECTOR -}}
{{- .Values.FRIGATE_DETECTOR -}}
{{- else if eq (include "gpu.profile" .) "amd" -}}
rocm
{{- else if eq (include "gpu.profile" .) "none" -}}
cpu
{{- else -}}
openvino
{{- end -}}
{{- end -}}

{{- define "gpu.frigateResource" -}}
{{- if .Values.FRIGATE_GPU_RESOURCE -}}
{{- .Values.FRIGATE_GPU_RESOURCE -}}
{{- else if eq (include "gpu.frigateDetector" .) "rocm" -}}
amd-igpu
{{- else if eq (include "gpu.frigateDetector" .) "openvino" -}}
intel-gpu
{{- end -}}
{{- end -}}

{{- define "gpu.immichMlBackend" -}}
{{- if .Values.IMMICH_ML_BACKEND -}}
{{- .Values.IMMICH_ML_BACKEND -}}
{{- else if eq (include "gpu.profile" .) "amd" -}}
rocm
{{- else if eq (include "gpu.profile" .) "none" -}}
cpu
{{- else -}}
openvino
{{- end -}}
{{- end -}}

{{- define "gpu.immichMlResource" -}}
{{- if .Values.IMMICH_ML_GPU_RESOURCE -}}
{{- .Values.IMMICH_ML_GPU_RESOURCE -}}
{{- else if eq (include "gpu.immichMlBackend" .) "rocm" -}}
amd-dgpu
{{- else if eq (include "gpu.immichMlBackend" .) "openvino" -}}
intel-gpu
{{- end -}}
{{- end -}}

{{- define "gpu.jellyfinHwaccel" -}}
{{- if .Values.JELLYFIN_HWACCEL -}}
{{- .Values.JELLYFIN_HWACCEL -}}
{{- else if eq (include "gpu.profile" .) "none" -}}
none
{{- else -}}
vaapi
{{- end -}}
{{- end -}}

{{- define "gpu.immichServerHwaccel" -}}
{{- if .Values.IMMICH_SERVER_HWACCEL -}}
{{- .Values.IMMICH_SERVER_HWACCEL -}}
{{- else if eq (include "gpu.profile" .) "none" -}}
none
{{- else -}}
vaapi
{{- end -}}
{{- end -}}

{{- define "gpu.ollamaGpu" -}}
{{- if .Values.OLLAMA_GPU -}}
{{- .Values.OLLAMA_GPU -}}
{{- else if eq (include "gpu.profile" .) "none" -}}
none
{{- else -}}
amd-dgpu
{{- end -}}
{{- end -}}
