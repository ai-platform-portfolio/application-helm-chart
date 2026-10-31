{{- define "application.name" -}}
{{- if gt (len .Release.Name) 45 -}}
{{- fail "release name must be at most 45 characters" -}}
{{- end -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "application.labels" -}}
app.kubernetes.io/name: application
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}
