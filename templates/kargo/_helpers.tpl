{{- define "application.kargoIdentity" -}}
{{- $url := required "platform.argocd.repository is required for Kargo" .Values.platform.argocd.repository -}}
{{- if not (regexMatch "^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\\.git)?$" $url) -}}{{- fail "Kargo requires an HTTPS github.com owner/repository URL" -}}{{- end -}}
{{- $repository := lower (trimSuffix ".git" (trimPrefix "https://github.com/" $url)) -}}
{{- $parts := splitList "/" $repository -}}
{{- $slug := trimAll "-" (regexReplaceAll "[^a-z0-9]+" (index $parts 1) "-") | trunc 28 | trimSuffix "-" | default "app" -}}
{{- $base := printf "%s-%s" $slug (trunc 12 (sha256sum $repository)) -}}
{{- dict "url" $url "repository" $repository "base" $base | toJson -}}
{{- end -}}
