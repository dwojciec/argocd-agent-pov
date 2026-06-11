{{- define "openshift-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "openshift-demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "openshift-demo.labels" -}}
helm.sh/chart: {{ include "openshift-demo.chart" . }}
{{ include "openshift-demo.selectorLabels" . }}
app.kubernetes.io/part-of: argocd-agent-pov
{{- end }}

{{- define "openshift-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openshift-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "openshift-demo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
