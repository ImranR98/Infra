{{/*
Derived host paths. MAIN_PARENT_DIR is the required root; runtime state lives
outside the repo at INFRA_STATE_DIR (default <HOME_DIR>/infra_state). Set a
value only when the tree differs. Shared by k3s-base and k3s-apps through the
k3s-common library chart.
*/}}
{{- define "path.main" -}}
{{- .Values.MAIN_PARENT_DIR -}}/Main
{{- end -}}

{{- define "path.media" -}}
{{- if .Values.MEDIA_DIR_PATH -}}{{ .Values.MEDIA_DIR_PATH }}{{- else -}}{{ include "path.main" . }}/Media{{- end -}}
{{- end -}}

{{- define "path.backups" -}}
{{- include "path.main" . -}}/Backups
{{- end -}}

{{- define "path.documents" -}}
{{- include "path.main" . -}}/Documents
{{- end -}}

{{- define "path.whatsapp" -}}
{{- include "path.main" . -}}/WhatsApp
{{- end -}}

{{- define "path.devicesync" -}}
{{- .Values.MAIN_PARENT_DIR -}}/deviceSync
{{- end -}}

{{- define "path.filePipelines" -}}
{{- .Values.MAIN_PARENT_DIR -}}/.file-pipelines
{{- end -}}

{{- define "path.syncthingData" -}}
{{- .Values.MAIN_PARENT_DIR -}}/.local/share/syncthing-data
{{- end -}}

{{- define "path.sandbox" -}}
{{- include "path.main" . -}}/Code/sandbox
{{- end -}}

{{- define "path.d4taConfig" -}}
{{- if .Values.D4TA_CONFIG_PATH -}}{{ .Values.D4TA_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Apps/D4TA/config{{- end -}}
{{- end -}}

{{- define "path.d4taLedger" -}}
{{- if .Values.D4TA_LEDGER_PATH -}}{{ .Values.D4TA_LEDGER_PATH }}{{- else -}}{{ include "path.main" . }}/Documents/Balance{{- end -}}
{{- end -}}

{{- define "path.d4taWatxtData" -}}
{{- if .Values.D4TA_WATXT_DATA_PATH -}}{{ .Values.D4TA_WATXT_DATA_PATH }}{{- else -}}{{ include "path.main" . }}/Backups/WhatsApp TXT{{- end -}}
{{- end -}}

{{- define "path.infraRoot" -}}
{{- if .Values.INFRA_ROOT -}}{{ .Values.INFRA_ROOT }}{{- else -}}{{ include "path.main" . }}/Infra{{- end -}}
{{- end -}}

{{- define "path.home" -}}
{{- if .Values.HOME_DIR -}}{{ .Values.HOME_DIR }}{{- else -}}{{ .Values.MAIN_PARENT_DIR }}{{- end -}}
{{- end -}}

{{- define "path.infraState" -}}
{{- if .Values.INFRA_STATE_DIR -}}{{ .Values.INFRA_STATE_DIR }}{{- else -}}{{ include "path.home" . }}/infra_state{{- end -}}
{{- end -}}

{{- define "path.journal" -}}
{{- if .Values.JOURNAL_DIR -}}{{ .Values.JOURNAL_DIR }}{{- else -}}/var/log/journal{{- end -}}
{{- end -}}
