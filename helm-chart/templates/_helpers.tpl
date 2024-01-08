{{/*
Expand the name of the chart.
*/}}
{{- define "tableau-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "tableau-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tableau-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tableau-server.labels" -}}
helm.sh/chart: {{ include "tableau-server.chart" . }}
{{ include "tableau-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tableau-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tableau-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "tableau-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tableau-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Tableau Server Config configMap name
*/}}
{{- define "tableau-server.configMap" -}}
{{ include "tableau-server.fullname" . }}-config
{{- end }}

{{/*
Tableau Server node environment configMap name
*/}}
{{- define "tableau-server.customEnvironment" -}}
{{ include "tableau-server.fullname" . }}-custom-environment
{{- end }}

{{/*
Tableau Server shared PCV name
*/}}
{{- define "tableau-server.bootstrapPvc" -}}
{{ include "tableau-server.fullname" . }}-bootstrap
{{- end }}
