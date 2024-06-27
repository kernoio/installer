{{/*
Expand the name of the chart.
*/}}
{{- define "nanobe-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "nanobe-chart.fullname" -}}
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
{{- define "nanobe-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nanobe-chart.labels" -}}
helm.sh/chart: {{ include "nanobe-chart.chart" . }}
{{ include "nanobe-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nanobe-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nanobe-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "nanobe-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nanobe-chart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate certificates
*/}}
{{- define "gen-tls-certs" -}}
{{ if .Values.global.tlsCert | empty }}
{{- $altNames := list ( print "localhost" ) ( printf "*.%s.svc" .Values.global.namespace ) ( printf "*.%s.svc.cluster.local" .Values.global.namespace ) ( printf "*.%s.pod.cluster.local" .Values.global.namespace ) -}}
{{- $ca := genCA "Kerno" 365000 -}}
{{- $cert := genSignedCert "Kerno" nil $altNames 365000 $ca -}}
{{- $_ := set .Values.global "tlsCert" ($cert.Cert | b64enc)  -}}
{{- $_ := set .Values.global "tlsKey" ($cert.Key | b64enc) -}}
{{- end -}}
{{- end -}}
