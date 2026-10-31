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

  volumes:
    {{- toYaml .root.Values.platform.pod.volumes | nindent 4 }}
{{- end -}}
