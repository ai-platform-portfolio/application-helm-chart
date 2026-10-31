{{- define "application.labels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/component: {{ .name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
{{- end -}}

{{- define "application.podTemplate" -}}
metadata:
  labels:
    {{- include "application.labels" . | nindent 4 }}
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: {{ .name }}
      image: {{ .component.image | quote }}
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: {{ .component.port }}

      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]

      readinessProbe:
        httpGet:
          path: {{ .component.healthPath | quote }}
          port: http

      livenessProbe:
        httpGet:
          path: {{ .component.healthPath | quote }}
          port: http

      resources:
        {{- toYaml (mergeOverwrite (deepCopy .root.Values.platform.resources) (default dict .component.resources)) | nindent 8 }}

      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: nginx-cache
          mountPath: /var/cache/nginx

  volumes:
    - name: tmp
      emptyDir: {}
    - name: nginx-cache
      emptyDir: {}
{{- end -}}
