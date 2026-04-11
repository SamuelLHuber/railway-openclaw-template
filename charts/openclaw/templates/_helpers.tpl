{{- define "openclaw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openclaw.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "openclaw.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "openclaw.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "openclaw.labels" -}}
helm.sh/chart: {{ include "openclaw.chart" . }}
app.kubernetes.io/name: {{ include "openclaw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "openclaw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openclaw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: openclaw
{{- end -}}

{{- define "openclaw.matchLabels" -}}
app: openclaw
{{- end -}}

{{- define "openclaw.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "openclaw.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "openclaw.backupSecretName" -}}
{{- if .Values.backup.restic.existingSecret -}}
{{- .Values.backup.restic.existingSecret -}}
{{- else -}}
{{- printf "%s-backup-restic" (include "openclaw.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "openclaw.restoreSecretName" -}}
{{- if .Values.restore.existingSecret -}}
{{- .Values.restore.existingSecret -}}
{{- else -}}
{{- include "openclaw.backupSecretName" . -}}
{{- end -}}
{{- end -}}
