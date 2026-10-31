{{- define "application.podTemplate" -}}
{{- $readiness := deepCopy .root.Values.platform.probes.readiness -}}
{{- $_ := set $readiness.httpGet "path" .component.healthPath -}}
{{- $liveness := deepCopy .root.Values.platform.probes.liveness -}}
{{- $_ := set $liveness.httpGet "path" .component.healthPath -}}
{{- $identity := default "" .component.identity -}}
{{- if and $identity (not (hasKey .root.Values.platform.azure.identities $identity)) -}}
{{- fail (printf "component %s references undefined identity %s" .name $identity) -}}
{{- end -}}
{{- $skip := list -}}
{{- if $identity -}}
{{- $_ := required (printf "identity %s needs clientId before deploying workloads" $identity) (index .root.Values.platform.azure.identities $identity).clientId -}}
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
    {{- toYaml .root.Values.platform.pod.securityContext | nindent 4 }}

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
      ports:
        - name: {{ .root.Values.platform.httpPortName }}
          containerPort: {{ .component.port }}

      securityContext:
        {{- toYaml .root.Values.platform.pod.containerSecurityContext | nindent 8 }}

      readinessProbe:
        {{- toYaml $readiness | nindent 8 }}

      livenessProbe:
        {{- toYaml $liveness | nindent 8 }}

      resources:
        {{- toYaml (mergeOverwrite (deepCopy .root.Values.platform.resources) (default dict .component.resources)) | nindent 8 }}

      volumeMounts:
        {{- toYaml .root.Values.platform.pod.volumeMounts | nindent 8 }}

    {{- range $name, $config := .component.sidecars }}
    {{- if eq $name $.name }}
    {{- fail (printf "container name %s is duplicated in component %s" $name $.name) }}
    {{- end }}
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config "identity" $identity "componentName" $.name) | nindent 6 | trim }}
    {{- end }}

  volumes:
    {{- toYaml .root.Values.platform.pod.volumes | nindent 4 }}
{{- end -}}
