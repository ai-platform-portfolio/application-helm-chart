{{/* Application-level rules are also applied during sync by RespectIgnoreDifferences. */}}
{{- define "application.rolloutDiff" -}}
- group: ""
  kind: Service
  namespace: {{ . | quote }}
  jsonPointers:
    - /spec/selector/rollouts-pod-template-hash
- group: gateway.networking.k8s.io
  kind: HTTPRoute
  namespace: {{ . | quote }}
  jsonPointers:
    - /metadata/labels/rollouts.argoproj.io~1gatewayapi-canary
  jqPathExpressions:
    - '.spec.rules[].backendRefs[] | select(.name | endswith("-canary")) | .weight'
    - '.spec.rules[] | select(any(.backendRefs[]; .name | endswith("-canary"))) | .backendRefs[0].weight'
{{- end -}}
