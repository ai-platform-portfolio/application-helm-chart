{{/* Resolve developer intent once per render; legacy resource maps remain supported. */}}
{{- define "application.defaults" -}}
{{- if not (get .Values "_applicationResolved") -}}
{{- if and .Values.platform.release.expectedRevision (ne .Values.platform.release.expectedRevision (default "" .Chart.AppVersion)) -}}
{{- fail "Packaged chart appVersion must match platform.release.expectedRevision" -}}
{{- end -}}
{{- $_ := set .Values "_applicationResolved" true -}}
{{- $_ := set .Values "name" (default .Values.namespace .Values.name) -}}
{{- $_ := set .Values "namespace" (default .Values.name .Values.namespace) -}}
{{- if .Values.hostname -}}
{{- $_ := set .Values.hosts "web" (dict "hostname" .Values.hostname) -}}
{{- end -}}
{{- if .Values.databases -}}
{{- if or .Values.postgres.databases .Values.postgres.roles .Values.postgres.migrations -}}
{{- fail "Use databases intent or advanced postgres resource maps, not both" -}}
{{- end -}}
{{- $generated := dict -}}
{{- range $name, $database := .Values.databases -}}
{{- $template := "application.databaseDefaults" -}}
{{- if eq $.Values.platform.postgres.backend "azure" -}}{{- $template = "application.azureDatabaseDefaults" -}}{{- end -}}
{{- $defaults := include $template (dict "root" $ "name" $name "database" $database) | fromYaml -}}
{{- $generated = mergeOverwrite $generated $defaults -}}
{{- end -}}
{{- $_ := mergeOverwrite .Values (mergeOverwrite $generated (deepCopy .Values)) -}}
{{- $_ := set .Values.platform.atlas "roleScope" (keys .Values.postgres.roles | sortAlpha) -}}
{{- $_ := set .Values.platform.atlas "rolePlanRepository" (default (printf "%s-roles" .Values.name) .Values.platform.atlas.rolePlanRepository) -}}
{{- $waves := dict "namespace" -40 "atlasAccess" -25 "atlasSchema" -20 "database" -10 "deployment" 10 "rollout" 10 "service" 10 "listenerSet" 10 "httpRoute" 10 -}}
{{- if eq .Values.platform.postgres.backend "azure" -}}
{{- $waves = mergeOverwrite $waves (dict "userAssignedIdentity" -35 "federatedIdentityCredential" -30 "database" -20 "atlasSchema" -15) -}}
{{- end -}}
{{- $_ := set .Values.platform "syncWaves" (mergeOverwrite $waves .Values.platform.syncWaves) -}}
{{- end -}}
{{- include "application.dependencies" . -}}
{{- range $name, $component := .Values.components -}}
{{- $_ := set $component "healthPath" (default "/" $component.healthPath) -}}
{{- if $component.readinessPath -}}
{{- $_ := set $component "readinessProbe" (mergeOverwrite (dict "httpGet" (dict "path" $component.readinessPath)) (default dict $component.readinessProbe)) -}}
{{- end -}}
{{- if and $.Values.hostname (eq $name $.Values.platform.gateway.defaultComponent) (not $component.route) -}}
{{- $_ := set $component "route" (dict "host" "web" "path" "/") -}}
{{- end -}}
{{- if $component.database -}}
{{- if not (hasKey $.Values.databases $component.database) -}}
{{- fail (printf "component %s references undefined database %s" $name $component.database) -}}
{{- end -}}
{{- $secret := printf "%s-connection" (include "application.resourceName" (dict "root" $ "name" $component.database)) -}}
{{- $envName := default "DATABASE_URL" $component.databaseEnv -}}
{{- range $entry := $component.env -}}
{{- if eq $entry.name $envName -}}{{- fail (printf "component %s declares %s twice" $name $envName) -}}{{- end -}}
{{- end -}}
{{- if eq $.Values.platform.postgres.backend "azure" -}}
{{- if and $component.identity (ne $component.identity (printf "%s-runtime" $component.database)) -}}{{- fail (printf "component %s must use its generated database identity" $name) -}}{{- end -}}
{{- $base := include "application.resourceName" (dict "root" $ "name" $component.database) -}}
{{- $user := printf "app_%s_app" (replace "-" "_" $base) -}}
{{- $database := index $.Values.postgres.databases $component.database -}}
{{- $host := printf "%s.postgres.database.azure.com" $.Values.platform.postgres.azure.serverName -}}
{{- $caBundle := required "platform.postgres.azure.caBundlePath is required" $.Values.platform.postgres.azure.caBundlePath -}}
{{- $_ := set $component "identity" (printf "%s-runtime" $component.database) -}}
{{- $_ := set $component "env" (concat (default list $component.env) (list (dict "name" $envName "value" (printf "postgresql://%s@%s:5432/%s?sslmode=verify-full&sslrootcert=%s" $user $host $database.name ($caBundle | urlquery))) (dict "name" "DATABASE_AUTH" "value" "entra"))) -}}
{{- else -}}
{{- $_ := set $component "env" (append (default list $component.env) (dict "name" $envName "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" "url")))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
