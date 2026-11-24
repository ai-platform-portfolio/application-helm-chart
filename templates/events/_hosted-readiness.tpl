{{- define "application.hostedReadiness" -}}
{{- with .Values.platform.hostedReadiness -}}
{{- $alert := . -}}
{{- range $name := list .agent .cluster .namespace .workload -}}
{{- if or (gt (len $name) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- fail "Hosted readiness needs DNS labels for agent, cluster, namespace and workload" -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$" .repository) -}}
{{- fail "Hosted readiness needs a GitHub repository" -}}
{{- end -}}
{{- if or (not $.Values.gatewayAccess) $.Values.platform.modelGateway.connectionOnly
          (not $.Values.platform.telemetry)
          (ne .namespace $.Values.platform.telemetry.namespace)
          (ne .workload $.Values.platform.telemetry.workload) -}}
{{- fail "Hosted readiness must target the deployed agent's private telemetry scope" -}}
{{- end -}}
{{- if or $.Values.events.sources $.Values.events.sensors $.Values.events.githubTokens -}}
{{- fail "Hosted readiness provisions its own event subscription and dispatch credential" -}}
{{- end -}}
{{- $native := include "application.hostedReadinessSpec" $alert | fromYaml -}}
{{- $_ := set $.Values.events "sensors" $native.sensors -}}
{{- $_ := set $.Values.events "githubTokens" $native.githubTokens -}}
{{- end -}}
{{- end -}}

{{- define "application.hostedReadinessSpec" -}}
githubTokens:
  dispatch:
    repository: {{ .repository | quote }}
    permissions: {contents: write}
sensors:
  readiness:
    loggingFields: null
    dependencies:
      - name: firing
        eventSourceName: grafana-alerts
        eventName: alert
        filters:
          data:
            - {path: body.status, type: string, value: ['^firing$']}
            - {path: body.alerts.0.status, type: string, value: ['^firing$']}
            - {path: body.alerts.0.labels.alertname, type: string, value: ['^Repeated Kubernetes readiness failures$']}
            - {path: 'body.alerts.#', type: number, value: ['1']}
            - path: body.alerts.0.labels.cluster
              type: string
              value: [{{ printf "^%s$" (regexQuoteMeta .cluster) | quote }}]
            - path: body.alerts.0.labels.namespace
              type: string
              value: [{{ printf "^%s$" (regexQuoteMeta .namespace) | quote }}]
    triggers:
      - template:
          name: dispatch-readiness
          http:
            url: {{ printf "https://api.github.com/repos/%s/dispatches" .repository | quote }}
            host: ""
            method: POST
            headers:
              Accept: application/vnd.github+json
              Content-Type: application/json
            secureHeaders:
              - name: Authorization
                valueFrom:
                  secretKeyRef: {name: dispatch, key: authorization}
            payload:
              - src: {dependencyName: firing, value: hosted-readiness-alert}
                dest: event_type
              - src: {dependencyName: firing, value: {{ .agent | quote }}}
                dest: client_payload.agent
              - src: {dependencyName: firing, value: {{ .workload | quote }}}
                dest: client_payload.workload
              {{- range $key, $path := dict "cluster" "labels.cluster" "namespace" "labels.namespace" "fingerprint" "fingerprint" "starts_at" "startsAt" }}
              - src:
                  dependencyName: firing
                  dataKey: {{ printf "body.alerts.0.%s" $path | quote }}
                dest: {{ printf "client_payload.%s" $key | quote }}
              {{- end }}
        policy:
          status: {allow: [204]}
        retryStrategy: {steps: 3, duration: 5s, factor: 2}
{{- end -}}
