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
{{- $identityConfig := index .root.Values.platform.azure.identities $identity -}}
{{- $clientIdConfigMap := include "application.azureResourceName" (dict "root" .root "name" $identity) | printf "%s-client-id" -}}
{{- if eq $identityConfig.create false -}}
{{- $clientIdConfigMap = required (printf "identity %s needs clientIdConfigMap when create=false" $identity) $identityConfig.clientIdConfigMap -}}
{{- end -}}
{{- $_ := set $container "env" (concat (default list $container.env) (list
  (dict "name" "AZURE_CLIENT_ID" "valueFrom" (dict "configMapKeyRef" (dict "name" $clientIdConfigMap "key" "clientId")))
  (dict "name" "AZURE_TENANT_ID" "value" (required "platform.azure.tenantId is required" .root.Values.platform.azure.tenantId))
  (dict "name" "AZURE_FEDERATED_TOKEN_FILE" "value" (printf "%s/%s" .root.Values.platform.azure.workloadIdentity.mountPath .root.Values.platform.azure.workloadIdentity.fileName))
  )) -}}
{{- $_ := set $container "volumeMounts" (append (default list $container.volumeMounts) (dict "name" "azure-identity-token" "mountPath" .root.Values.platform.azure.workloadIdentity.mountPath "readOnly" true)) -}}
{{- end -}}
{{- toYaml $container -}}
{{- end -}}
