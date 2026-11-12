{{/*
Resource presets. Every container in this chart picks exactly one tier — the
numbers below are the only values allowed (validate.sh rejects anything else).
Each tier carries the CPU request, memory request and memory limit; the memory
limit is 4x the request, sized from 25 days of cadvisor history in Prometheus.

  # ladder tier (nindent = the column where `resources:` belongs)
  {{- include "infra.resources" (dict "tier" "small") | nindent 10 }}

  # ladder tier with a justified ceiling above the 4x rule (comment why inline)
  {{- include "infra.resources" (dict "tier" "xlarge" "memLimit" "16Gi") | nindent 10 }}

  # CPU-heavy despite a small memory footprint
  {{- include "infra.resources" (dict "tier" "2xlarge" "cpu" "1") | nindent 10 }}

  # generic device plugin grant (adds infra.local/<device>: "1" to both sides)
  {{- include "infra.resources" (dict "tier" "3xlarge" "device" "vaapi") | nindent 10 }}

  # explicit sizing for memory that tracks a model/cache, not steady state:
  # memRequest and memLimit are mandatory here
  {{- include "infra.resources" (dict "tier" "custom" "memRequest" "1Gi" "memLimit" "8Gi") | nindent 10 }}

Kept in both k3s-apps and k3s-base because Helm helpers are chart-scoped.
*/}}
{{- define "infra.resources" -}}
{{- $presets := dict
  "tiny"    (dict "cpu" "10m"  "req" "32Mi"  "lim" "128Mi")
  "small"   (dict "cpu" "10m"  "req" "64Mi"  "lim" "256Mi")
  "medium"  (dict "cpu" "25m"  "req" "128Mi" "lim" "512Mi")
  "large"   (dict "cpu" "50m"  "req" "256Mi" "lim" "1Gi")
  "xlarge"  (dict "cpu" "50m"  "req" "512Mi" "lim" "2Gi")
  "2xlarge" (dict "cpu" "100m" "req" "1Gi"   "lim" "4Gi")
  "3xlarge" (dict "cpu" "250m" "req" "2Gi"   "lim" "8Gi")
-}}
{{- $tier := .tier -}}
{{- if not $tier -}}
{{- fail "infra.resources: tier is required" -}}
{{- end -}}
{{- $cpu := "" -}}
{{- $req := "" -}}
{{- $lim := "" -}}
{{- if eq $tier "custom" -}}
{{- if or (not .memRequest) (not .memLimit) -}}
{{- fail "infra.resources: tier custom requires memRequest and memLimit" -}}
{{- end -}}
{{- $cpu = .cpu | default "100m" -}}
{{- $req = .memRequest -}}
{{- $lim = .memLimit -}}
{{- else -}}
{{- $p := index $presets $tier -}}
{{- if not $p -}}
{{- fail (printf "infra.resources: unknown tier %q" $tier) -}}
{{- end -}}
{{- $cpu = $p.cpu -}}
{{- $req = $p.req -}}
{{- $lim = $p.lim -}}
{{- end -}}
{{- if .cpu -}}
{{- $cpu = .cpu -}}
{{- end -}}
{{- if .memLimit -}}
{{- $lim = .memLimit -}}
{{- end -}}
{{- $device := .device -}}
resources:
  requests:
    cpu: {{ $cpu }}
    memory: {{ $req }}
    {{- with $device }}
    infra.local/{{ . }}: "1"
    {{- end }}
  limits:
    {{- with .cpuLimit }}
    cpu: {{ . }}
    {{- end }}
    memory: {{ $lim }}
    {{- with $device }}
    infra.local/{{ . }}: "1"
    {{- end }}
{{- end -}}
