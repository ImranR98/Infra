{{/*
Shared building blocks for the D$CPLN app templates. Each app still owns its
Deployment (mounts, env, schedule, image) while the repeated bits — pod and
container security contexts, the readiness probe, and the Service — come from
these named templates.

  securityContext:
    {{- include "dscpln.podSecurityContext" (dict "uid" .Values.MY_UID "seLevel" "s0") | nindent 8 }}

  securityContext:
    {{- include "dscpln.containerSecurityContext" (dict "uid" .Values.MY_UID "readOnlyRootFilesystem" true) | nindent 12 }}

  readinessProbe:
    {{- include "dscpln.readinessProbe" (dict "path" "/x/api/health" "port" "http") | nindent 12 }}

  ---
  {{ include "dscpln.service" (dict "name" "x" "port" 8080) }}
*/}}

{{- define "dscpln.podSecurityContext" -}}
fsGroup: {{ .uid }}
# Only fix ownership when the volume root does not already match: local PVs
# are bind mounts of host trees, and the default (Always) policy makes the
# kubelet recursively chgrp the whole tree on every pod start.
fsGroupChangePolicy: OnRootMismatch
{{- if or .seType .seLevel }}
seLinuxOptions:
  {{- with .seType }}
  type: {{ . }}
  {{- end }}
  {{- with .seLevel }}
  level: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "dscpln.containerSecurityContext" -}}
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
{{- if .readOnlyRootFilesystem }}
readOnlyRootFilesystem: true
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "dscpln.readinessProbe" -}}
httpGet:
  path: {{ .path }}
  port: {{ .port }}
periodSeconds: 30
timeoutSeconds: 5
failureThreshold: 3
{{- if .initialDelaySeconds }}
initialDelaySeconds: {{ .initialDelaySeconds }}
{{- end }}
{{- end -}}

{{- define "dscpln.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: apps
spec:
  type: ClusterIP
  selector:
    app: {{ .selector | default .name }}
  ports:
    - name: http
      port: {{ .port }}
      targetPort: {{ .targetPort | default .port }}
{{- end -}}
