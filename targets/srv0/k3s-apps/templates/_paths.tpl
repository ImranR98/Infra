{{/*
Derived host paths. MAIN_PARENT_DIR is the only required root; every other
path defaults to the conventional location under it. Set the corresponding
value only when the tree differs. Kept in both charts because Helm helpers are
chart-scoped.
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

{{- define "path.dscplnConfig" -}}
{{- if .Values.DSCPLN_CONFIG_PATH -}}{{ .Values.DSCPLN_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Automation/dscpln-config{{- end -}}
{{- end -}}

{{- define "path.dscplnLedger" -}}
{{- if .Values.DSCPLN_LEDGER_PATH -}}{{ .Values.DSCPLN_LEDGER_PATH }}{{- else -}}{{ include "path.main" . }}/Documents/Balance{{- end -}}
{{- end -}}

{{- define "path.waTxt" -}}
{{- if .Values.WA_TXT_PATH -}}{{ .Values.WA_TXT_PATH }}{{- else -}}{{ include "path.main" . }}/Backups/WhatsApp TXT{{- end -}}
{{- end -}}

{{- define "path.infraRoot" -}}
{{- if .Values.INFRA_ROOT -}}{{ .Values.INFRA_ROOT }}{{- else -}}{{ include "path.main" . }}/Infra{{- end -}}
{{- end -}}

{{- define "path.home" -}}
{{- if .Values.HOME_DIR -}}{{ .Values.HOME_DIR }}{{- else -}}{{ .Values.MAIN_PARENT_DIR }}{{- end -}}
{{- end -}}

{{- define "path.journal" -}}
{{- if .Values.JOURNAL_DIR -}}{{ .Values.JOURNAL_DIR }}{{- else -}}/var/log/journal{{- end -}}
{{- end -}}
