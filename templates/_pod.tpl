{{- define "application.podTemplate" -}}
{{- $readiness := deepCopy .root.Values.platform.probes.readiness -}}
{{- $_ := set $readiness.httpGet "path" .component.healthPath -}}
{{- $readiness = mergeOverwrite $readiness (default dict .component.readinessProbe) -}}
{{- $liveness := deepCopy .root.Values.platform.probes.liveness -}}
{{- $_ := set $liveness.httpGet "path" .component.healthPath -}}
{{- $identity := default "" .component.identity -}}
{{- if and $identity (not (hasKey .root.Values.platform.azure.identities $identity)) -}}
{{- fail (printf "component %s references undefined identity %s" .name $identity) -}}
{{- end -}}
{{- $skip := list -}}
{{- if $identity -}}
{{- $identityConfig := index .root.Values.platform.azure.identities $identity -}}
{{- if not (or $identityConfig.clientId $identityConfig.reflectToApplication) -}}
{{- fail (printf "identity %s needs clientId or generated ConfigMap" $identity) -}}
{{- end -}}
{{- range $name, $container := merge (deepCopy (default dict .component.sidecars)) (default dict .component.initContainers) -}}
{{- if not $container.azureIdentity -}}
{{- $skip = append $skip $name -}}
{{- end -}}
{{- end -}}
{{- end -}}
metadata:
  {{- if and $identity $skip }}
  annotations:
    azure.workload.identity/skip-containers: {{ join ";" $skip | quote }}
  {{- end }}
  labels:
    {{- if $identity }}
    azure.workload.identity/use: "true"
    {{- end }}
    {{- include "application.labels" . | nindent 4 }}
spec:
  {{- if $identity }}
  serviceAccountName: {{ $identity }}
  automountServiceAccountToken: false
  {{- end }}
  securityContext:
    {{- if and .component.database (eq .root.Values.platform.postgres.backend "cnpg") }}
    {{- toYaml (mergeOverwrite (dict "fsGroup" 65532) (deepCopy .root.Values.platform.pod.securityContext)) | nindent 4 }}
    {{- else }}
    {{- toYaml .root.Values.platform.pod.securityContext | nindent 4 }}
    {{- end }}

  {{- if .component.initContainers }}
  initContainers:
    {{- range $name, $config := .component.initContainers }}
    {{- if or (eq $name $.name) (hasKey (default dict $.component.sidecars) $name) }}
    {{- fail (printf "container name %s is duplicated in component %s" $name $.name) }}
    {{- end }}
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config "identity" $identity "componentName" $.name) | nindent 6 | trim }}
    {{- end }}
  {{- end }}

  containers:
    - name: {{ .name }}
      image: {{ .component.image | quote }}
      imagePullPolicy: {{ .root.Values.platform.pod.imagePullPolicy }}
      {{- $env := deepCopy (default list .component.env) }}
      {{- if and $identity (not (index .root.Values.platform.azure.identities $identity).clientId) }}
      {{- $configMap := printf "%s-client-id" (include "application.resourceName" (dict "root" .root "name" $identity)) }}
      {{- $env = append $env (dict "name" "AZURE_CLIENT_ID" "valueFrom" (dict "configMapKeyRef" (dict "name" $configMap "key" "clientId"))) }}
      {{- end }}
      {{- with $env }}
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .component.command }}
      command: {{ . | toJson }}
      {{- end }}
      {{- with .component.args }}
      args: {{ . | toJson }}
      {{- end }}
      {{- if .component.port }}
      ports:
        - name: {{ .root.Values.platform.httpPortName }}
          containerPort: {{ .component.port }}
      {{- end }}

      securityContext:
        {{- toYaml .root.Values.platform.pod.containerSecurityContext | nindent 8 }}

      {{- if or .component.port .component.readinessProbe }}
      readinessProbe:
        {{- toYaml (ternary $readiness .component.readinessProbe (not (empty .component.port))) | nindent 8 }}
      {{- end }}

      {{- if or .component.port .component.livenessProbe }}
      livenessProbe:
        {{- toYaml (default $liveness .component.livenessProbe) | nindent 8 }}
      {{- end }}

      resources:
        {{- toYaml (mergeOverwrite (deepCopy .root.Values.platform.resources) (default dict .component.resources)) | nindent 8 }}

      volumeMounts:
        {{- toYaml .root.Values.platform.pod.volumeMounts | nindent 8 }}
        {{- if and .component.database (eq .root.Values.platform.postgres.backend "cnpg") }}
        - {name: database-client, mountPath: /etc/postgres, readOnly: true}
        {{- end }}

    {{- range $name, $config := .component.sidecars }}
    {{- if eq $name $.name }}
    {{- fail (printf "container name %s is duplicated in component %s" $name $.name) }}
    {{- end }}
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config "identity" $identity "componentName" $.name) | nindent 6 | trim }}
    {{- end }}

  volumes:
    {{- toYaml .root.Values.platform.pod.volumes | nindent 4 }}
    {{- if and .component.database (eq .root.Values.platform.postgres.backend "cnpg") }}
    - name: database-client
      secret:
        secretName: {{ printf "%s-connection" (include "application.resourceName" (dict "root" .root "name" .component.database)) | quote }}
        # libpq accepts a root-owned key with group-read permission. fsGroup
        # grants the non-root runtime access; no subPath pins an old certificate.
        defaultMode: 0640
        items: [{key: ca.crt, path: ca.crt}, {key: tls.crt, path: tls.crt}, {key: tls.key, path: tls.key}]
    {{- end }}
{{- end -}}
