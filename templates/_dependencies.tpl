{{/* Expand minimal dependency intent into the existing native resource maps. */}}
{{- define "application.dependencies" -}}
{{- $azure := .Values.platform.azure -}}
{{- $used := not (empty .Values.storage) -}}
{{- range $name, $component := .Values.components -}}
{{- if or $component.storage $component.model -}}{{- $used = true -}}{{- end -}}
{{- end -}}
{{- if and $used (or $azure.roleAssignments $azure.identities $azure.storageContainers) -}}
{{- fail "Dependency intent cannot be combined with advanced Azure access maps" -}}
{{- end -}}
{{- range $key, $request := .Values.storage -}}
{{- $base := include "application.resourceName" (dict "root" $ "name" $key) -}}
{{- if and $.Values.platform.lifecycle.cleanup.enabled (ne (default "retain" $request.reclaimPolicy) "delete") -}}
{{- fail (printf "preview cleanup requires reclaimPolicy: delete for storage %s" $key) -}}
{{- end -}}
{{- if hasKey $azure.storageContainers $key -}}{{- fail "Use storage intent or advanced storageContainers, not both for the same key" -}}{{- end -}}
{{- $_ := set $azure.storageContainers $key (dict "azureName" $base "reclaimPolicy" (default "retain" $request.reclaimPolicy)) -}}
{{- end -}}
{{- range $name, $component := .Values.components -}}
{{- if or $component.storage $component.model -}}
{{- $used = true -}}
{{- $identity := printf "%s-runtime" $name -}}
{{- if and $component.database (eq $.Values.platform.postgres.backend "azure") -}}
{{- $identity = printf "%s-runtime" $component.database -}}
{{- end -}}
{{- if and $component.identity (ne $component.identity $identity) -}}{{- fail "Dependency intent owns the component identity" -}}{{- end -}}
{{- $_ := set $component "identity" $identity -}}
{{- $base := include "application.resourceName" (dict "root" $ "name" $identity) -}}
{{- if not (hasKey $azure.identities $identity) -}}
{{- $_ := set $azure.identities $identity (dict "azureName" (printf "id-%s" $base) "reflectToApplication" true) -}}
{{- end -}}
{{- $env := dict "APPLICATION_REVISION" (default "local" $.Chart.AppVersion) -}}
{{- if $component.storage -}}
{{- if not (hasKey $.Values.storage $component.storage) -}}{{- fail (printf "component %s references undefined storage %s" $name $component.storage) -}}{{- end -}}
{{- $container := index $azure.storageContainers $component.storage -}}
{{- $_ := set $env "BLOB_ACCOUNT_URL" (printf "https://%s.blob.core.windows.net" (required "platform.azure.storageAccount.name is required" $azure.storageAccount.name)) -}}
{{- $_ := set $env "BLOB_CONTAINER" $container.azureName -}}
{{- $condition := printf "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '%s')" $container.azureName -}}
{{- $_ := set $azure.roleAssignments (printf "%s-blob" $name) (dict "identity" $identity "roleName" "application-blob-data" "roleDefinitionId" (required "platform.azure.blobRoleId is required" $azure.blobRoleId) "scope" "storageAccount" "condition" $condition) -}}
{{- end -}}
{{- if $component.model -}}
{{- $model := required (printf "component %s references undefined model %s" $name $component.model) (index $.Values.platform.models $component.model) -}}
{{- $_ := set $env "MODEL_BASE_URL" (required "model endpoint is required" $model.endpoint) -}}
{{- $_ := set $env "MODEL_DEPLOYMENT" (required "model deployment is required" $model.deployment) -}}
{{- $scope := printf "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.CognitiveServices/accounts/%s/projects/%s" $azure.subscriptionId (required "model resourceGroup is required" $model.resourceGroup) (required "model account is required" $model.account) (required "model project is required" $model.project) -}}
{{- $_ := set $azure.roleAssignments (printf "%s-model" $name) (dict "identity" $identity "roleName" "Foundry User" "scope" "storageAccount" "armScope" $scope) -}}
{{- end -}}
{{- if $.Values.platform.telemetryEndpoint -}}
{{- $_ := set $env "OTEL_EXPORTER_OTLP_ENDPOINT" $.Values.platform.telemetryEndpoint -}}
{{- $_ := set $env "OTEL_SERVICE_NAME" (printf "%s/%s" $.Values.name $name) -}}
{{- end -}}
{{- range $key, $value := $env -}}
{{- range $entry := $component.env -}}
{{- if eq $entry.name $key -}}{{- fail (printf "component %s duplicates platform environment %s" $name $key) -}}{{- end -}}
{{- end -}}
{{- $_ := set $component "env" (append (default list $component.env) (dict "name" $key "value" $value)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $used -}}
{{- $waves := dict "namespace" -40 "userAssignedIdentity" -35 "federatedIdentityCredential" -30 "storageContainer" -29 "roleAssignment" -25 "serviceAccount" -20 "deployment" 10 "service" 10 -}}
{{- $_ := set .Values.platform "syncWaves" (mergeOverwrite $waves .Values.platform.syncWaves) -}}
{{- end -}}
{{- end -}}
