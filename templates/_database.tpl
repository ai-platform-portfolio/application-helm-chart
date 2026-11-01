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
    passwords:
      {{ $base }}-migrator:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-35'
        spec:
          length: 48
          digits: 8
          symbols: 0
          allowRepeat: true
      {{ $base }}-runtime:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-35'
        spec:
          length: 48
          digits: 8
          symbols: 0
          allowRepeat: true
    externalSecrets:
      {{ $base }}-migrator:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-35'
        spec:
          refreshPolicy: CreatedOnce
          target:
            name: {{ $base }}-migrator
            creationPolicy: Orphan
            immutable: true
          dataFrom:
          - sourceRef:
              generatorRef:
                apiVersion: generators.external-secrets.io/v1alpha1
                kind: Password
                name: {{ $base }}-migrator
      {{ $base }}-migrator-copy:
        metadata:
          name: {{ $base }}-migrator
          namespace: {{ $atlas.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-30'
        spec:
          refreshInterval: 1m
          secretStoreRef:
            name: {{ $atlas.sourceStore | quote }}
            kind: SecretStore
          target:
            name: {{ $base }}-migrator
          data:
          - secretKey: password
            remoteRef:
              key: {{ $base }}-migrator
              property: password
      {{ $base }}-runtime:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-35'
        spec:
          refreshPolicy: CreatedOnce
          target:
            name: {{ $base }}-runtime
            creationPolicy: Orphan
            immutable: true
          dataFrom:
          - sourceRef:
              generatorRef:
                apiVersion: generators.external-secrets.io/v1alpha1
                kind: Password
                name: {{ $base }}-runtime
      {{ $base }}-runtime-copy:
        metadata:
          name: {{ $base }}-runtime
          namespace: {{ $atlas.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-30'
        spec:
          refreshInterval: 1m
          secretStoreRef:
            name: {{ $atlas.sourceStore | quote }}
            kind: SecretStore
          target:
            name: {{ $base }}-runtime
          data:
          - secretKey: password
            remoteRef:
              key: {{ $base }}-runtime
              property: password
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
                url: {{ printf "postgres://%s:{{ .password }}@%s:%v/%s?sslmode=verify-full&sslrootcert=/etc/postgres/ca.crt" $runtime $atlas.connection.host $atlas.connection.port $databaseName | quote }}
                ca.crt: {{ "{{ index . \"ca.crt\" }}" | quote }}
          data:
          - secretKey: password
            remoteRef:
              key: {{ $base }}-runtime
              property: password
          - secretKey: ca.crt
            remoteRef:
              key: {{ default (printf "%s-ca" $pg.cluster) $pg.caSecret | quote }}
              property: ca.crt
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
      {{ $base }}-atlas-reader:
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
          - {{ $base }}-migrator
          - {{ $base }}-runtime
          verbs:
          - get
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
          - {{ $base }}-runtime
          - {{ default (printf "%s-ca" $pg.cluster) $pg.caSecret | quote }}
          verbs:
          - get
    roleBindings:
      {{ $base }}-atlas-reader:
        metadata:
          namespace: {{ $pg.namespace | quote }}
          annotations:
            argocd.argoproj.io/sync-wave: '-34'
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: Role
          name: {{ $base }}-atlas-reader
        subjects:
        - kind: ServiceAccount
          name: {{ $atlas.sourceReader | quote }}
          namespace: {{ $atlas.namespace | quote }}
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
      passwordSecret: {{ $base }}-migrator
      memberOf: [{{ $owner }}, {{ $databaseName | quote }}]
    {{ $runtime }}:
      login: true
      passwordSecret: {{ $base }}-runtime
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
