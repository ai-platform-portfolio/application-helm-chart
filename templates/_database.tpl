{{/* Expand one requested database into its related managed resources. */}}
{{- define "application.databaseDefaults" -}}
{{- $base := include "application.resourceName" (dict "root" .root "name" .name) -}}
{{- $sql := printf "app_%s" (replace "-" "_" $base) -}}
{{- $owner := printf "%s_owner" $sql -}}
{{- $migrator := printf "%s_migrator" $sql -}}
{{- $runtime := printf "%s_app" $sql -}}
{{- $databaseName := default $sql .database.name -}}
{{- if has $databaseName (list $owner $migrator $runtime) -}}
{{- fail "database name must differ from its owner, migrator and runtime roles" -}}
{{- end -}}
{{- $pg := .root.Values.platform.postgres -}}
{{- $atlas := .root.Values.platform.atlas -}}
platform:
  credentials:
    certificates:
      {{ $base }}-client:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-35'
        spec:
          secretName: {{ $base }}-client
          commonName: {{ $runtime | quote }}
          issuerRef: {{ $pg.clientCertificate.issuerRef | toJson }}
          duration: {{ $pg.clientCertificate.duration | quote }}
          renewBefore: {{ $pg.clientCertificate.renewBefore | quote }}
          privateKey: {rotationPolicy: Always}
          usages: [digital signature, client auth]
    externalSecrets:
      {{ $base }}-connection:
        metadata:
          namespace: {{ .root.Values.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-30'
        spec:
          refreshInterval: 1m
          secretStoreRef:
            name: {{ $base }}-store
            kind: SecretStore
          target:
            name: {{ $base }}-connection
            template:
              engineVersion: v2
              data:
                url: {{ printf "postgres://%s@%s:%v/%s?sslmode=verify-full&sslrootcert=/etc/postgres/ca.crt&sslcert=/etc/postgres/tls.crt&sslkey=/etc/postgres/tls.key" $runtime $atlas.connection.host $atlas.connection.port $databaseName | quote }}
                ca.crt: {{ `{{ index . "ca.crt" }}` | quote }}
                tls.crt: {{ `{{ index . "tls.crt" }}` | quote }}
                tls.key: {{ `{{ index . "tls.key" }}` | quote }}
          data:
          - secretKey: tls.crt
            remoteRef: {key: {{ $base }}-client, property: tls.crt}
          - secretKey: tls.key
            remoteRef: {key: {{ $base }}-client, property: tls.key}
          - secretKey: ca.crt
            remoteRef: {key: {{ $base }}-client, property: ca.crt}
    secretStores:
      {{ $base }}-store:
        metadata:
          namespace: {{ .root.Values.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-33'
        spec:
          provider:
            kubernetes:
              remoteNamespace: {{ $pg.namespace | quote }}
              server:
                url: https://kubernetes.default.svc
                caProvider:
                  type: ConfigMap
                  name: kube-root-ca.crt
                  key: ca.crt
              auth:
                serviceAccount:
                  name: {{ $base }}-reader
    serviceAccounts:
      {{ $base }}-reader:
        metadata:
          namespace: {{ .root.Values.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-34'
        automountServiceAccountToken: false
    roles:
      {{ $base }}-runtime-reader:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-34'
        rules:
        - apiGroups:
          - ''
          resources:
          - secrets
          resourceNames:
          - {{ $base }}-client
          verbs:
          - get
    roleBindings:
      {{ $base }}-runtime-reader:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-34'
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: Role
          name: {{ $base }}-runtime-reader
        subjects:
        - kind: ServiceAccount
          name: {{ $base }}-reader
          namespace: {{ .root.Values.namespace | quote }}

postgres:
  databases:
    {{ .name }}:
      name: {{ $databaseName | quote }}
      owner: {{ $owner | quote }}
      reclaimPolicy: {{ default $pg.databaseReclaimPolicy .database.reclaimPolicy }}
  roles:
    # samerole HBA checks this database-named group; it owns nothing.
    {{ $databaseName | quote }}: {}
    {{ $owner }}: {}
    {{ $migrator }}:
      login: true
      authentication: certificate
      memberOf: [{{ $owner }}, {{ $databaseName | quote }}]
    {{ $runtime }}:
      login: true
      authentication: certificate
      memberOf: [{{ $databaseName | quote }}]
  migrations:
    {{ .name }}-access:
      database: {{ .name }}
      role: {{ $migrator }}
      schema: public
      revisionsSchema: atlas_access_revisions
      syncWave: -5
      roleVars: {runtime: {{ $runtime }}}
      local:
        1_access.sql: |
{{ .root.Files.Get "files/postgres/1_access.sql" | indent 10 }}
        {{- if eq (default "append" .database.runtimeAccess) "readWrite" }}
        2_read_write.sql: |
{{ .root.Files.Get "files/postgres/2_read_write.sql" | indent 10 }}
        {{- end }}
    {{- with .database.migration }}
    {{ $.name }}:
      database: {{ $.name }}
      role: {{ $migrator }}
      schema: public
      revisionsSchema: atlas_schema_revisions
      syncWave: 0
      repository: {{ .repository | quote }}
      tag: {{ .tag | quote }}
    {{- end }}
{{- end -}}

{{/* A managed database has a distinct Entra runtime identity and Atlas-owned SQL. */}}
{{- define "application.azureDatabaseDefaults" -}}
{{- if and .database.reclaimPolicy (ne .database.reclaimPolicy "delete") -}}
{{- fail "Azure database cleanup requires reclaimPolicy: delete" -}}
{{- end -}}
{{- $base := include "application.resourceName" (dict "root" .root "name" .name) -}}
{{- $sql := printf "app_%s" (replace "-" "_" $base) -}}
{{- $databaseName := default $sql .database.name -}}
{{- $runtime := printf "%s_app" $sql -}}
{{- $identity := printf "%s-runtime" .name -}}
{{- $identityBase := include "application.resourceName" (dict "root" .root "name" $identity) -}}
{{- $pg := .root.Values.platform.postgres -}}
{{- $_ := required "platform.postgres.azure.serverName is required" $pg.azure.serverName -}}
{{- $_ := required "platform.postgres.azure.serverResourceGroup is required" $pg.azure.serverResourceGroup -}}
platform:
  azure:
    identities:
      {{ $identity }}:
        azureName: {{ printf "id-%s" $base | quote }}
        reflectToApplication: true

postgres:
  databases:
    {{ .name }}:
      name: {{ $databaseName | quote }}
  roles:
    {{ $runtime }}:
      login: true
      authentication: entra
  migrations:
    {{ .name }}-identity:
      database: {{ .name }}
      role: {{ $runtime }}
      revisionsSchema: atlas_identity_revisions
      syncWave: -10
      roleVars: {runtime: {{ $runtime }}}
      principalIdConfigMap: {{ $identityBase }}-principal-id
      local:
        1_entra.sql: |
{{ .root.Files.Get "files/postgres/1_entra.sql" | indent 10 }}
    {{ .name }}-access:
      database: {{ .name }}
      role: {{ $runtime }}
      schema: public
      revisionsSchema: atlas_access_revisions
      syncWave: -5
      roleVars: {runtime: {{ $runtime }}}
      local:
        1_access.sql: |
{{ .root.Files.Get "files/postgres/1_access.sql" | indent 10 }}
        {{- if eq (default "append" .database.runtimeAccess) "readWrite" }}
        2_read_write.sql: |
{{ .root.Files.Get "files/postgres/2_read_write.sql" | indent 10 }}
        {{- end }}
    {{- with .database.migration }}
    {{ $.name }}:
      database: {{ $.name }}
      role: {{ $runtime }}
      schema: public
      revisionsSchema: atlas_schema_revisions
      syncWave: 0
      repository: {{ .repository | quote }}
      tag: {{ .tag | quote }}
    {{- end }}
{{- end -}}
