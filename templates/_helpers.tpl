{{- define "application.labels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/component: {{ .name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
{{- end -}}

{{- define "application.azureResourceName" -}}
{{- $base := printf "%s-%s-%s" .root.Values.namespace .root.Release.Name .name -}}
{{- printf "%s-%s" (trimSuffix "-" (trunc 37 $base)) (trunc 12 (sha256sum $base)) -}}
{{- end -}}

{{- define "application.extraContainer" -}}
{{- $container := mergeOverwrite (dict
  "imagePullPolicy" .root.Values.platform.pod.imagePullPolicy
  "securityContext" (deepCopy .root.Values.platform.pod.containerSecurityContext)
  "resources" (deepCopy .root.Values.platform.resources)
  ) (omit (deepCopy .config) "azureIdentity") -}}
{{- $_ := set $container "name" .name -}}
{{- if .config.azureIdentity -}}
{{- $identity := required (printf "component %s needs an identity for container %s" .componentName .name) .identity -}}
{{- end -}}
{{- toYaml $container -}}
{{- end -}}
