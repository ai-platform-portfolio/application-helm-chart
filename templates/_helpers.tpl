{{- define "application.labels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/component: {{ .name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
{{- end -}}

{{- define "application.resourceName" -}}
{{- $base := printf "%s-%s-%s" .root.Values.namespace .root.Release.Name .name -}}
{{- printf "%s-%s" (trimSuffix "-" (trunc 37 $base)) (trunc 12 (sha256sum $base)) -}}
{{- end -}}

{{/* Shared verbatim with cleanup's atomic ownership-scope test. */}}
{{- define "application.roleConfig" -}}
env {{ .Values.platform.atlas.roleEnvironment | toJson }} {
  include = [
    {{- range .Values.platform.atlas.roleScope }}
    {{ printf "%s[type=role|user]" . | toJson }},
    {{- end }}
  ]
  schema {
    src = "file://schema.hcl"
    mode {
      schemas     = false
      objects     = false
      roles       = true
      permissions = false
      sensitive   = ALLOW
    }
  }
}
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

{{- define "application.azureScope" -}}
{{- $azure := .root.Values.platform.azure -}}
{{- $resource := index $azure .target -}}
{{- $provider := "" -}}
{{- if eq .target "keyVault" -}}
{{- $provider = "Microsoft.KeyVault/vaults" -}}
{{- else if eq .target "storageAccount" -}}
{{- $provider = "Microsoft.Storage/storageAccounts" -}}
{{- else -}}
{{- fail (printf "unsupported Azure scope target %s" .target) -}}
{{- end -}}
{{- printf "/subscriptions/%s/resourceGroups/%s/providers/%s/%s" (required "platform.azure.subscriptionId is required" $azure.subscriptionId) (required (printf "platform.azure.%s.resourceGroup is required" .target) $resource.resourceGroup) $provider (required (printf "platform.azure.%s.name is required" .target) $resource.name) -}}
{{- end -}}

{{/* Credential map keys default names; native metadata can bind another name/namespace. */}}
{{- define "application.credentialMetadata" -}}
{{- $metadata := mergeOverwrite (dict "name" .name "namespace" .root.Values.namespace) (deepCopy (default dict .config.metadata)) -}}
{{- $_ := required "credential metadata.namespace or application namespace is required" $metadata.namespace -}}
metadata:
  {{- toYaml $metadata | nindent 2 }}
{{- end -}}
