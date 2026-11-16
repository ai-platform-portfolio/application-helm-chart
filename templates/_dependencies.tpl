{{/* Expand minimal dependency intent into the existing native resource maps. */}}
{{- define "application.dependencies" -}}
{{- $azure := .Values.platform.azure -}}
{{- $used := not (empty .Values.storage) -}}
{{- range $name, $component := .Values.components -}}
{{- if or $component.storage $component.model $component.gatewayAccess -}}{{- $used = true -}}{{- end -}}
{{- end -}}
{{- if and $used (or $azure.roleAssignments $azure.identities $azure.storageContainers) -}}
{{- fail "Dependency intent cannot be combined with advanced Azure access maps" -}}
{{- end -}}
{{- range $key, $request := .Values.storage -}}
{{- $base := include "application.resourceName" (dict "root" $ "name" $key) -}}
{{- if and (eq (get $.Values.platform.namespaceLabels "gitops.platform/preview") "true") (ne (default "retain" $request.reclaimPolicy) "delete") -}}
{{- fail (printf "preview cleanup requires reclaimPolicy: delete for storage %s" $key) -}}
{{- end -}}
{{- if hasKey $azure.storageContainers $key -}}{{- fail "Use storage intent or advanced storageContainers, not both for the same key" -}}{{- end -}}
{{- $_ := set $azure.storageContainers $key (dict "azureName" $base "reclaimPolicy" (default "retain" $request.reclaimPolicy)) -}}
{{- end -}}
{{- range $name, $component := .Values.components -}}
{{- if or $component.storage $component.model $component.gatewayAccess -}}
{{- $used = true -}}
{{- $identity := printf "%s-runtime" $name -}}
{{- if and $component.database (eq $.Values.platform.postgres.backend "azure") -}}
{{- $identity = printf "%s-runtime" $component.database -}}
{{- end -}}
{{- if and $component.identity (ne $component.identity $identity) -}}{{- fail "Dependency intent owns the component identity" -}}{{- end -}}
{{- $_ := set $component "identity" $identity -}}
{{- $base := include "application.resourceName" (dict "root" $ "name" $identity) -}}
{{- if not (or (hasKey $azure.identities $identity) (and $component.database (eq $.Values.platform.postgres.backend "azure"))) -}}
{{- $_ := set $azure.identities $identity (dict "azureName" (printf "id-%s" $base) "reflectToApplication" true) -}}
{{- end -}}
{{- $env := dict "APPLICATION_REVISION" (default "local" $.Chart.AppVersion) -}}
{{- if $component.gatewayAccess -}}
{{- if $component.model -}}{{- fail "Select direct model intent or gatewayAccess, never both" -}}{{- end -}}
{{- $gateway := $.Values.platform.modelGateway -}}
{{- $policy := required "Gateway policy is not configured" (index $gateway.policies $component.gatewayAccess.policy) -}}
{{- $accessName := include "application.resourceName" (dict "root" $ "name" (printf "gateway-%s" $name)) -}}
{{- $_ := set $env "MODEL_CONNECTION_MODE" "gateway" -}}
{{- $_ := set $env "MODEL_AUTH_METHOD" "api_key" -}}
{{- $_ := set $env "MODEL_BASE_URL" (required "platform.modelGateway.endpoint is required" $gateway.endpoint) -}}
{{- range $capability, $intent := $policy.capabilities -}}
{{- $prefix := "" -}}{{- if ne $capability "default" -}}{{- $prefix = printf "%s_" (upper $capability) -}}{{- end -}}
{{- $secretName := printf "%s-%s" $accessName $capability -}}
{{- $_ := set $env (printf "%sMODEL_DEPLOYMENT_NAME" $prefix) $intent.model -}}
{{- $_ := set $env (printf "%sMODEL_API_KEY_SECRET_URI" $prefix) (printf "%s/secrets/%s" (trimSuffix "/" $gateway.vaultUri) $secretName) -}}
{{- $vault := include "application.azureScope" (dict "root" $ "target" "keyVault") -}}
{{- $_ := set $azure.roleAssignments (printf "%s-gateway-%s" $identity $capability) (dict "generated" true "identity" $identity "roleName" "Key Vault Secrets User" "armScope" (printf "%s/secrets/%s" $vault $secretName) "retainUntilGatewayRevocation" true) -}}
{{- end -}}
{{- end -}}
{{- if $component.storage -}}
{{- if not (hasKey $.Values.storage $component.storage) -}}{{- fail (printf "component %s references undefined storage %s" $name $component.storage) -}}{{- end -}}
{{- $container := index $azure.storageContainers $component.storage -}}
{{- $_ := set $env "BLOB_ACCOUNT_URL" (printf "https://%s.blob.core.windows.net" (required "platform.azure.storageAccount.name is required" $azure.storageAccount.name)) -}}
{{- $_ := set $env "BLOB_CONTAINER" $container.azureName -}}
{{- $condition := printf "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '%s')" $container.azureName -}}
{{- $assignmentKey := printf "%s-blob" $identity -}}
{{- if hasKey $azure.roleAssignments $assignmentKey -}}
{{- $condition = printf "(%s OR %s)" (index $azure.roleAssignments $assignmentKey).condition $condition -}}
{{- end -}}
{{- $_ := set $azure.roleAssignments $assignmentKey (dict "generated" true "identity" $identity "roleName" "application-blob-data" "roleDefinitionId" (required "platform.azure.blobRoleId is required" $azure.blobRoleId) "scope" "storageAccount" "condition" $condition) -}}
{{- end -}}
{{- if $component.model -}}
{{- $model := default dict (index $.Values.platform.models $component.model) -}}
{{- $_ := required (printf "component %s references undefined model %s" $name $component.model) $model -}}
{{- $_ := set $env "MODEL_BASE_URL" (required "model endpoint is required" $model.endpoint) -}}
{{- $_ := set $env "MODEL_DEPLOYMENT" (required "model deployment is required" $model.deployment) -}}
{{- $scope := printf "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.CognitiveServices/accounts/%s" $azure.subscriptionId (required "model resourceGroup is required" $model.resourceGroup) (required "model account is required" $model.account) -}}
{{- $_ := set $azure.roleAssignments (printf "%s-model-%s" $identity (sha256sum (lower $scope) | trunc 12)) (dict "generated" true "identity" $identity "roleName" "Cognitive Services OpenAI User" "scope" "storageAccount" "armScope" $scope) -}}
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
