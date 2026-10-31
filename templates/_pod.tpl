{{- define "application.podTemplate" -}}
{{- $readiness := deepCopy .root.Values.platform.probes.readiness -}}
{{- $_ := set $readiness.httpGet "path" .component.healthPath -}}
{{- $liveness := deepCopy .root.Values.platform.probes.liveness -}}
{{- $_ := set $liveness.httpGet "path" .component.healthPath -}}
metadata:
  labels:
    {{- include "application.labels" . | nindent 4 }}
spec:
  securityContext:
    {{- toYaml .root.Values.platform.pod.securityContext | nindent 4 }}

  {{- if .component.initContainers }}
  initContainers:
    {{- range $name, $config := .component.initContainers }}
    {{- if or (eq $name $.name) (hasKey (default dict $.component.sidecars) $name) }}
    {{- fail (printf "container name %s is duplicated in component %s" $name $.name) }}
    {{- end }}
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config) | nindent 6 | trim }}
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
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config) | nindent 6 | trim }}
    {{- end }}

  volumes:
    {{- toYaml .root.Values.platform.pod.volumes | nindent 4 }}
{{- end -}}
