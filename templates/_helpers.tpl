{{- define "application.labels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/component: {{ .name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
{{- end -}}

{{- define "application.extraContainer" -}}
{{- $container := mergeOverwrite (dict
  "imagePullPolicy" .root.Values.platform.pod.imagePullPolicy
  "securityContext" (deepCopy .root.Values.platform.pod.containerSecurityContext)
  "resources" (deepCopy .root.Values.platform.resources)
  ) (deepCopy .config) -}}
{{- $_ := set $container "name" .name -}}
{{- toYaml $container -}}
{{- end -}}
