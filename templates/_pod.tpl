{{- define "application.podTemplate" -}}
{{- $readiness := deepCopy .root.Values.platform.probes.readiness -}}
{{- $_ := set $readiness.httpGet "path" .component.healthPath -}}
{{- $liveness := deepCopy .root.Values.platform.probes.liveness -}}
{{- $_ := set $liveness.httpGet "path" .component.healthPath -}}
{{- $identity := default "" .component.identity -}}
{{- if and $identity (not (hasKey .root.Values.platform.azure.identities $identity)) -}}
{{- fail (printf "component %s references undefined identity %s" .name $identity) -}}
{{- end -}}
{{- $clientIdConfigMap := "" -}}
{{- if $identity -}}
{{- $identityConfig := index .root.Values.platform.azure.identities $identity -}}
{{- $clientIdConfigMap = printf "%s-client-id" (include "application.azureResourceName" (dict "root" .root "name" $identity)) -}}
{{- if eq $identityConfig.create false -}}
{{- $clientIdConfigMap = required (printf "identity %s needs clientIdConfigMap when create=false" $identity) $identityConfig.clientIdConfigMap -}}
{{- end -}}
{{- end -}}
metadata:
  labels:
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
      {{- if $identity }}
      env:
        - name: AZURE_CLIENT_ID
          valueFrom:
            configMapKeyRef:
              name: {{ $clientIdConfigMap }}
              key: clientId
        - name: AZURE_TENANT_ID
          value: {{ required "platform.azure.tenantId is required" .root.Values.platform.azure.tenantId | quote }}
        - name: AZURE_FEDERATED_TOKEN_FILE
          value: {{ printf "%s/%s" .root.Values.platform.azure.workloadIdentity.mountPath .root.Values.platform.azure.workloadIdentity.fileName | quote }}
      {{- end }}
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
        {{- if $identity }}
        - name: azure-identity-token
          mountPath: {{ .root.Values.platform.azure.workloadIdentity.mountPath | quote }}
          readOnly: true
        {{- end }}

    {{- range $name, $config := .component.sidecars }}
    {{- if eq $name $.name }}
    {{- fail (printf "container name %s is duplicated in component %s" $name $.name) }}
    {{- end }}
    - {{ include "application.extraContainer" (dict "root" $.root "name" $name "config" $config "identity" $identity "componentName" $.name) | nindent 6 | trim }}
    {{- end }}

  volumes:
    {{- toYaml .root.Values.platform.pod.volumes | nindent 4 }}
    {{- if $identity }}
    - name: azure-identity-token
      projected:
        sources:
          - serviceAccountToken:
              audience: {{ .root.Values.platform.azure.workloadIdentity.audience | quote }}
              expirationSeconds: {{ .root.Values.platform.azure.workloadIdentity.expirationSeconds }}
              path: {{ .root.Values.platform.azure.workloadIdentity.fileName | quote }}
    {{- end }}
{{- end -}}
