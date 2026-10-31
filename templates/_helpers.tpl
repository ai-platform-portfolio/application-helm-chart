{{- define "application.metadata" -}}
name: {{ default .name .resource.name | quote }}
{{- if .namespaced }}
namespace: {{ required (printf "namespace is required for %s" .name) (default .root.Values.namespace .resource.namespace) | quote }}
{{- end }}
labels:
  {{- $labels := dict "app.kubernetes.io/instance" .root.Release.Name "app.kubernetes.io/managed-by" .root.Release.Service -}}
  {{- toYaml (mergeOverwrite $labels (default dict .resource.labels)) | nindent 2 }}
{{- with .resource.annotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
