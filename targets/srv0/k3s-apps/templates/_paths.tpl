{{/*
Derived host paths. MAIN_PARENT_DIR is the required root; runtime state lives
outside the repo at INFRA_STATE_DIR (default <HOME_DIR>/infra_state). Set a
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
{{- if .Values.DSCPLN_CONFIG_PATH -}}{{ .Values.DSCPLN_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Apps/DSCPLN/config{{- end -}}
{{- end -}}

{{- define "path.watxtConfig" -}}
{{- if .Values.WATXT_CONFIG_PATH -}}{{ .Values.WATXT_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Apps/WATXT/config{{- end -}}
{{- end -}}

{{- define "path.fl0wConfig" -}}
{{- if .Values.FL0W_CONFIG_PATH -}}{{ .Values.FL0W_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Apps/FL0W/config{{- end -}}
{{- end -}}

{{- define "path.da5hConfig" -}}
{{- if .Values.DA5H_CONFIG_PATH -}}{{ .Values.DA5H_CONFIG_PATH }}{{- else -}}{{ include "path.main" . }}/Code/Apps/DA5H/config{{- end -}}
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

{{- define "path.infraState" -}}
{{- if .Values.INFRA_STATE_DIR -}}{{ .Values.INFRA_STATE_DIR }}{{- else -}}{{ include "path.home" . }}/infra_state{{- end -}}
{{- end -}}

{{- define "path.journal" -}}
{{- if .Values.JOURNAL_DIR -}}{{ .Values.JOURNAL_DIR }}{{- else -}}/var/log/journal{{- end -}}
{{- end -}}
