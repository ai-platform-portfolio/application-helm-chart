# Application chart

Application developers declare intent; the chart owns Kubernetes resource defaults,
Argo registration, database roles, credentials, RBAC, verified TLS and ordering.
The app repository needs only a values file like [managed.yaml](examples/managed.yaml):

```yaml
name: sample-app
hostname: sample.example.test
components:
  web:
    image: registry.example/web@sha256:...
    port: 8080
  api:
    image: registry.example/api@sha256:...
    port: 8000
    healthPath: /healthz
    readinessPath: /readyz
    database: messages
databases:
  messages:
    migration: {repository: app-migrations, tag: reviewed-source-sha}
```

`name` defaults the namespace. `hostname` exposes the `web` component by default
(configurable through `platform.gateway.defaultComponent`); other components stay
internal. Health defaults to `/`; app-specific health/readiness paths are meaningful
app inputs. Images stay digest-pinned. `database: messages` injects DATABASE_URL and
mounts its client certificate/key and CA only into that component; `databaseEnv`
can change the variable name.

Each database request derives isolated SQL/resource names from namespace, release
and database key. The chart creates a non-login owner, migration/runtime logins,
a cert-manager runtime client certificate, named ESO reader access, a CNPG database
and separate protected access/application migrations. Runtime defaults are SELECT/INSERT on application
tables in public; metadata stays in private revision schemas. No SQL permissions or
secret plumbing belongs in the developer values. These defaults are versioned access
migrations, not automatic permission-drift reconciliation. Keep names/releases stable;
changing an applied access policy requires a new forward migration, not editing v1.
The platform operator owns those changes and approved cleanup. Optional database
`name` overrides its SQL name. Database deletion retains the platform's safe default;
set `reclaimPolicy: delete` explicitly for disposable data. Do not combine minimal `databases` with advanced
`postgres` ownership maps.

Each database also gets a NOLOGIN connection group with the exact SQL database
name. Only its migration/runtime logins join it; the group owns no objects and
receives no SQL privileges. The shared PostgreSQL package uses a TLS client-certificate
`samerole` HBA rule for chart-generated logins, so membership restricts connections
to their own database even before access migrations run. New applications/PRs
need no server configuration edits. PostgreSQL's native [samerole rule](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html)
and the existing per-database SQL grants enforce separate checks. Platform policy
must be installed before deploying this profile; Helm alone cannot configure HBA.

Minimal database intent uses certificate authentication. The platform supplies the
namespaced `postgres-client` Issuer and a fixed Atlas client certificate/mount
through its shared PostgreSQL package. `platform.postgres.clientCertificate`
configures issuer/lifetime defaults; `platform.atlas.clientCertificate` contains
native sslcert/sslkey paths for the existing operator mount. Minimal profiles
produce no password resources/variables and no per-preview Atlas credential copies
or Deployment edits. Roles and memberships remain Atlas-owned. Certificate requests
use the generated runtime login as commonName; only that runtime leaf Secret is
readable by the application's ESO identity. CNPG's current shared server/client CA
is delivered through the issued Secret's public ca.crt.

ESO refreshes the app copy every minute. The database consumer mounts ca.crt,
tls.crt and tls.key read-only with 0640 permissions and a default fsGroup 65532;
explicit pod security settings still override that group. Directory mounts avoid
subPath pinning during renewal. The frontend receives no database credentials.
Actual issuance, mounted-key access, renewal and operator readiness must be proved
in live acceptance. Cleanup must remove the source Certificate and its named Secret
explicitly; cert-manager does not necessarily garbage-collect Secrets on deletion.
Upgrading an already-deployed password profile needs reviewed credential ownership
and orphan-Secret cleanup; do not blindly adopt an existing password Secret.

Advanced `postgres.roles` retains password authentication by default, requiring
`passwordSecret` for each login. Set `authentication: certificate` to omit its
password attribute/vars and use the fixed Atlas certificate for its migrations;
certificate roles require `login: true` and reject `passwordSecret`. The generic
`platform.credentials.certificates` map accepts native cert-manager Certificate
specs alongside the existing credential resource maps. No Certificate is rendered
unless requested; these client certificates are independent of Envoy HTTPS.

### Argo bootstrap — platform operator

The reusable registration template is `templates/argocd/application.yaml`. Render
**only that template** for one-time registration, after deployment approval:

```sh
helm template sample-app /path/to/application-helm-chart \
  -f /path/to/app/deploy/values.yaml \
  --set platform.argocd.enabled=true \
  --set-string platform.argocd.repository=https://github.com/org/app.git \
  --set-string platform.argocd.revision=<reviewed-values-commit> \
  --set-string platform.argocd.chartRevision=<reviewed-chart-commit> \
  --show-only templates/argocd/application.yaml > /tmp/application.yaml
```

Review `/tmp/application.yaml` before the separately authorized apply. Do not apply
an unfiltered bootstrap render. Argo then renders workloads from the pinned chart
and app values; it explicitly disables child registration to prevent recursion.
Registration is manual-sync. It adds a cascade finalizer only when the opt-in
ordered cleanup below is enabled. Bootstrap metadata is operator input, not developer Kubernetes YAML.
GitOps remains strictly shared packages; the app repository contains no raw Argo
manifest, credential YAML or bespoke deployment validator.

Shared CNPG/ESO/Atlas/Argo/Gateway prerequisites, Atlas entitlement/schema-plan repo,
current-generation health checks and approved HBA access must already be ready.
The operator can inspect rendered Database/migration resources for the exact SQL
names to authorize. Templates and unit tests do not prove live SQL/application
acceptance. Existing database/role ownership is not adopted.

### Disposable cleanup — platform operator

For an exclusive application namespace using minimal `databases` intent, set
`platform.lifecycle.cleanup.enabled=true` at registration. The registration template
forwards the cleanup settings into its child render. Every database must explicitly
set `reclaimPolicy: delete`; retained databases and advanced `postgres` ownership
maps reject this mode. Applications add no cleanup manifests or scripts.

Argo deletes normal resources in **reverse sync-wave order**: workloads first,
then migrations, the CNPG database (through its SQL-deletion finalizer), normal
Atlas resources/access and finally the application namespace. There is no shell
coordinator, workload patching, custom polling or cleanup access in the app namespace.
This uses the native [Application deletion implementation](https://github.com/argoproj/argo-cd/blob/v3.5.5/controller/sort_delete.go),
checked at the installed Argo v3.5.5. Keep the chart's dependency wave ordering.

Deleting an AtlasSchema leaves SQL roles behind. After ordinary cascading deletion
finishes, a **PostDelete AtlasSchema** requests an empty role state with the same
exact include scope, shared connection, cloud repository and lint/review policy.
It uses the same spec helper as normal role management. Argo's installed Atlas
health check waits for current-generation Ready; failed hooks are recreated by
Argo. The Application's deletion finalizer remains until hooks complete. No
independent SQL script or second database role owner is added.

Atlas migration-state Secrets have native owner references; ESO copies and the
application namespace also use Kubernetes garbage collection. The source runtime
client Secrets currently lack certificate owner references. A small PostDelete
Job therefore calls official, digest-pinned kubectl directly to delete only those
derived leaf names, with delete-only RBAC. It has no shell, SQL credentials or
shared-secret reads; UID65532/read-only root and a temporary discovery cache.
`image` and `timeoutSeconds` (default 900) remain operator settings for this Job.
The Atlas operator separately receives named get access to its existing shared
connection and cloud-token Secrets during PostDelete. Shared CA/Atlas credentials,
services, registry artifacts and Terraform state are preserved.

Prerequisites include the existing Atlas entitlement/plan repository, native Argo
PostDelete and current-generation Atlas health checks. Keep namespace, release,
database keys and SQL names stable for the environment lifetime; historical SQL
objects from renamed identities require a separate migration plan. Do not bypass
CNPG or Application finalizers. A failed/approval-pending cleanup leaves the
Application terminating for diagnosis and native retry. Role lint/review flags
are preserved but do not reliably require approval for DROP ROLE.

Local PostgreSQL/Atlas proof covers fresh empty desired state, database ownership
blocking early role removal, three isolated identities, preserved other/shared
roles and repeated no-op cleanup. These CLI tests plus controller source checks
are not native live-hook acceptance. Reverse-wave deletion, garbage collection,
current-generation hook health and partial/in-flight deployment deletion/retry must
still be proved live before unattended previews. Helm hook annotations prevent
install-time execution; the supported lifecycle here is Argo Application deletion.
Automatic PR ApplicationSets remain separate work.

## Advanced resource configuration

This chart lets an application describe its workloads without writing Kubernetes
manifests. Each entry in `components` creates a Deployment or Argo Rollout and
its Services. A component with a `route` also gets an HTTPS HTTPRoute. Each entry in
`hosts` creates an HTTPS ListenerSet and certificate request.
The chart creates the application Namespace. Maps support any number of
components and hosts.

Application developers normally supply only:

```yaml
components:
  frontend:
    image: registry.example/frontend@sha256:...
    port: 8080
    healthPath: /
    route: {host: public, path: /}

  backend:
    delivery: rollout
    image: registry.example/backend@sha256:...
    port: 8000
    healthPath: /api/healthz
    route: {host: public, path: /api}
```

The map key becomes the workload and Service name. `delivery` defaults to
`deployment`; use `rollout` for progressive delivery. Omit `route` for an
internal component. A component may override `replicas` and `resources` when it
needs more capacity. Images must use immutable digests.

Add named `sidecars` and `initContainers` to a component when its pod needs
more containers. The map key becomes the container name. These entries accept
Kubernetes container fields such as `command`, `args`, `env`, `ports`, `resources`
and `volumeMounts`; the chart supplies the image pull, security and resource
defaults. Both Deployment and Rollout pods use the same container template.

```yaml
components:
  backend:
    initContainers:
      prepare:
        image: registry.example/prepare@sha256:...
        command: ["/prepare"]
    sidecars:
      telemetry:
        image: registry.example/telemetry@sha256:...
        command: ["/collector"]
```

The platform supplies the namespace and hosts in an environment values file.
The chart's `values.yaml` holds repeatable Gateway, resource, pod security,
probe, Service and Rollout defaults. `_helpers.tpl` contains shared rendering
functions; `_pod.tpl` assembles the pod from those defaults. The optional
`platform.gateway.httpRedirect.enabled` defaults to `true` and adds one HTTP
redirect route per host. Set it to `false` only when the platform supplies the
redirect elsewhere. Redirects attach to the Gateway's HTTP listener; application
routes attach to the ListenerSet's HTTPS listener. Each host uses an exact
hostname and its own certificate; the values schema rejects wildcard hosts.
Application routes remain separate per component
so Rollouts can manage the backend route's weights. The example Rollout promotes
immediately. A later delivery change will add measured steps and blocking tests.

For advanced resource maps, Argo CD sync wave annotations are absent by default.
Minimal database intent supplies its dependency waves automatically. Set only the resource kinds
that need ordering in `platform.syncWaves`. Supported keys are `namespace`,
`deployment`, `service`, `rollout`, `listenerSet` and `httpRoute`. Each configured
wave applies to every rendered resource of that kind, including redirect routes.
Azure resources also support `serviceAccount`, `userAssignedIdentity`,
`federatedIdentityCredential`, `roleAssignment` and `storageContainer` keys.

```yaml
platform:
  syncWaves:
    namespace: -20
    service: -10
    rollout: 0
    httpRoute: 10
```

## Optional Azure resources

The platform can set `platform.azure.identities` and
`platform.azure.storageContainers` in environment values. The chart creates
ServiceAccounts in the application namespace and ASO identity, federation,
role and private Blob container resources in the existing `azure-resources`
namespace. The ASO credential there is installed by GitOps; application pods
never receive it. Kubernetes names include the namespace, release and a hash
so multiple applications can safely use this central namespace. Azure names
must still be unique and must name **new** resources; adopting an existing
Terraform-owned identity or container needs a separate ownership transfer.

An identity creates a new user-assigned managed identity by default, plus one
federated credential for its application ServiceAccount. Set a component's
`identity` to the identity map key. The ServiceAccount carries
`azure.workload.identity/client-id` and tenant annotations, and the pod carries
`azure.workload.identity/use: "true"`. The AKS Workload Identity webhook injects
the Azure environment variables and token volume. Sidecars and init containers
opt in with `azureIdentity: true`; the chart adds other container names to the
webhook's skip-containers annotation.

The platform supplies `identities.<name>.clientId` after provisioning. A first
render can create identities, federation, roles and containers without workloads
or a client ID; no ServiceAccount is emitted until its client ID is supplied.
ASO exports client and principal IDs to separate central ConfigMaps. After ASO
reports Ready, platform delivery reads the client ID and supplies it as a Helm
input before enabling workloads. A workload referencing an identity without a
client ID fails rendering. Sync waves alone cannot pass runtime values into a
Helm render. This chart does not automate that delivery handoff; it must be
implemented when wiring the GitOps application deployment. No Helm lookup or
post-deployment annotation patch is used.

For previews, set `create: false`, `azureName`, `resourceGroup` and `clientId`
to reference a shared identity owned by platform GitOps. The chart creates its
preview-specific federated credential and annotated ServiceAccount; platform
GitOps grants the shared identity its Azure roles once. The shared identity
itself is not provisioned by this chart. Azure limits the number of federated
credentials on one identity, so preview concurrency needs a bounded policy
before enabling this path. Keep real client IDs in platform deployment inputs.

`platform.azure.roleAssignments` is a map of assignments, each with `identity`,
`roleName` and `scope` (`keyVault` or `storageAccount`). The template builds the
ARM scope from the platform resource configuration. For example:

```yaml
platform:
  azure:
    roleAssignments:
      backend-blobs:
        identity: backend
        roleName: Storage Blob Data Reader
        scope: storageAccount
```

Each assignment grants its configured role on the whole vault or storage account; do not enable them for disposable previews.
Storage containers are private, created in the existing platform account, and
do not imply a workload write grant. Keep account, vault, group, subscription,
tenant and issuer values in platform-controlled deployment inputs, with real
account IDs out of Git. Argo must have permission for the cross-namespace
resources and health checks for ASO Ready conditions; configure sync waves in
environment values when a workload must wait for Azure provisioning. Preview
cleanup must remove the federated credential before the shared identity's
platform lifecycle ends.

Main containers accept native Kubernetes `env` entries, including Secret references.
An optional component `readinessProbe` merges with the platform readiness defaults;
`healthPath` still supplies liveness. For a database-backed API:

```yaml
components:
  api:
    # image, port and healthPath are configured as usual.
    env:
      - name: DATABASE_URL
        valueFrom: {secretKeyRef: {name: runtime-database, key: url}}
    readinessProbe:
      httpGet: {path: /api/readyz}
```

## Render the example

```sh
helm template poc . -f examples/application.yaml -f examples/preview.yaml
helm template poc . -f examples/application.yaml -f examples/staging.yaml
helm template poc . -f examples/application.yaml -f examples/production.yaml
```

The example image digests and domains are placeholders. Platform operators and
the shared Gateway are installed through GitOps. ASO database and Atlas
migration templates are separate follow-up work.

## Test the chart

Use Helm 3.22.1 and the pinned [helm-unittest](https://github.com/helm-unittest/helm-unittest)
plugin for the same checks as CI:

```sh
helm plugin install https://github.com/helm-unittest/helm-unittest.git --version v1.2.1
helm unittest --strict .

for environment in preview staging production; do
  helm lint . -f examples/application.yaml -f "examples/${environment}.yaml"
done
```

Each YAML suite under `tests/` targets a resource or a related resource group,
with shared inputs in `tests/fixtures/`. `identity.yaml` groups managed identities,
federated credentials and their role assignments; `gateway-routes.yaml` groups
ListenerSets and HTTPRoutes. Their suites select each resource kind explicitly.
Keep assertions expanded and test cases
separated by blank lines. The suites check rendered resources and invalid inputs
without a cluster. This keeps assertions in the Helm ecosystem without a separate language
or test runner. Native `helm test` exercises an installed release through test pods;
those integration checks belong to the later deployment validation work.

## Optional PostgreSQL and Atlas resources

### Why deploy through the Atlas operator?

This platform uses Argo CD for application delivery. The Atlas operator exposes
database deployment status as Kubernetes conditions, so Argo can wait for the
required schema before starting application workloads. It also provides native
resource interfaces for versioned/declarative deployments, scheduled drift
checks and security scans, with the appropriate Atlas configuration and licence.
These features still need configuration and acceptance tests; installing the
operator alone does not enable them.

The alternative considered was the official Atlas Terraform provider through
Atlantis. It supports schema/migration deployments, reviews and protected down
migrations, and remains a valid choice for a Terraform-oriented platform. For
this portfolio, it would add Terraform state for schemas and require explicit
coordination between Atlantis completion and Argo application delivery. Its
resource deletion behavior also differs: `atlas_schema` invokes schema cleaning,
while `atlas_migration` deletion performs no database cleanup. This decision is
about the fit with the existing delivery system, not a claim that the provider
is immature or incapable.

The tradeoff is that the operator needs cluster access, credential RBAC, health
checks and lifecycle configuration. CI still plans/lints/tests changes; CNPG
still handles database provisioning and backup/recovery. Deleting an Atlas CR
does not delete its SQL objects, so preview cleanup remains explicit.

The self-service interface is the application's Helm values: `postgres.databases`,
`postgres.roles` and `postgres.migrations`. The chart renders CNPG `Database`,
`AtlasSchema` and `AtlasMigration` resources; the operators reconcile them.
Developers declare roles once in `postgres.roles`, and the chart generates their
Atlas HCL. Platform values supply the shared connections, exact ownership scope
and review settings. There is no additional Atlas library in the Terraform
repository or Terraform ownership of these SQL objects.

Application migration files belong with application code. The migration values
reference a versioned Atlas registry artifact and its revision; publishing those
artifacts remains delivery integration work. Migration files describe application
schema changes and do not require a second declaration of the chart-owned roles.
Preview delivery, cleanup and rollback still need the integration tests below.

Sources: [Atlas operator](https://atlasgo.io/integrations/kubernetes),
[Terraform provider](https://atlasgo.io/integrations/terraform),
[schema resource lifecycle](https://github.com/ariga/terraform-provider-atlas/blob/v0.10.3/internal/provider/atlas_schema_resource.go),
[migration resource lifecycle](https://github.com/ariga/terraform-provider-atlas/blob/v0.10.3/internal/provider/atlas_migration_resource.go).

### Current chart inputs

The `postgres` maps describe databases, roles and migration deployments. They
are empty by default. CNPG `Database` resources live in `platform.postgres.namespace`;
Atlas resources and credential-read RBAC live in `platform.atlas.namespace`.
Related Atlas resources share `templates/atlas.yaml` and `tests/atlas_test.yaml`;
CNPG databases use `postgres.yaml` and `postgres_test.yaml`.

```yaml
postgres:
  databases:
    api:
      name: preview_pr42
      owner: preview_pr42_owner
      reclaimPolicy: delete

  roles:
    preview_pr42_owner: {}
    preview_pr42_migrator:
      login: true
      passwordSecret: preview-pr42-migrator
      memberOf: [preview_pr42_owner]
    preview_pr42_app:
      login: true
      passwordSecret: preview-pr42-runtime

  migrations:
    api:
      database: api
      role: preview_pr42_migrator
      repository: preview-poc
      tag: commit-sha
```

These are platform-controlled environment inputs. Application developers keep
migration content in the application repository; the PR delivery mechanism will
supply names, Secret references and registry revisions. No passwords belong in
values. Required central password Secrets must exist before these resources
reconcile; this chart does not generate or copy application credentials.

The platform separately sets `platform.atlas.roleScope` to the exact SQL role
names this release owns, and `rolePlanRepository` to an Atlas plan repository.
Role inspection uses that explicit include list with schemas, objects and
permissions disabled. Login passwords use Secret-backed Atlas variables.
Membership is restricted to other roles declared by this release, and role
creation cannot request superuser, CREATEROLE or CREATEDB. The bootstrap role
manager and existing service roles must stay outside the scope. This is a
trusted platform configuration boundary, not database-enforced tenant isolation.
Never claim the same database or role from multiple releases.

AtlasSchema owns the declared roles. Each AtlasMigration owns its SQL changes:
application objects or a separate access history, never overlapping grants. The chart does not invent table privileges for the
runtime role or let two resources reconcile the same grants. CNPG owns database
creation and its database owner; object ownership follows the migration login or
explicit reviewed migration SQL. Existing resources need a deliberate ownership
transfer before adoption.

Migration connections are assembled from the selected database and login role,
with the direct PostgreSQL host, port and verified TLS parameters in
`platform.atlas.connection`. The GitOps prerequisites supply the CA mount and
Atlas bot token. The generated Role permits only `get` on named Secrets used by
this release. An optional migration `devURLSecret` supplies a dedicated empty dev
database URL; never point it at the target database. Before deployment, verify
that any operator-created dev database uses the target PostgreSQL major version,
satisfies Pod Security and fits the cluster, or provide a compatible dev URL.

Sync waves remain absent by default. A platform environment can use:

```yaml
platform:
  atlas:
    roleScope: [preview_pr42_owner, preview_pr42_migrator, preview_pr42_app]
    rolePlanRepository: preview-roles
  syncWaves:
    namespace: -40
    atlasAccess: -30
    atlasSchema: -20
    database: -10
    atlasMigration: 0
    deployment: 10
    rollout: 10
```

The Argo current-generation health checks from GitOps are prerequisites for this
ordering. Application credential delivery, PostgreSQL HBA rules for the new
logins, migration publication and live two-preview isolation checks are still
integration work. Rendering tests do not prove PostgreSQL privileges or Atlas
licence availability.

### Credential delivery

`templates/credentials/` renders reusable ESO and reader access resources from
named maps in `platform.credentials`: `passwords`, `externalSecrets`, `secretStores`,
`serviceAccounts`, `roles` and `roleBindings`. Empty maps render nothing. Map keys
default resource names, and namespace defaults to the application namespace.
Optional native `metadata` overrides names/namespaces and supplies labels or waves.
Specs, rules, roleRef and subjects retain their native Kubernetes shape; ESO
`{{ ... }}` templates are passed through without Helm `tpl` evaluation.

```yaml
platform:
  credentials:
    externalSecrets:
      runtime-database:
        metadata:
          annotations: {argocd.argoproj.io/sync-wave: "-30"}
        spec:
          secretStoreRef: {name: app-vault, kind: SecretStore}
          target: {name: runtime-database}
          data:
            - secretKey: url
              remoteRef: {key: app-database-url}
```

The platform caller owns trusted credential policy and name references; application
pods receive only the selected Secret keys. No application names or provider
settings are embedded in these templates. Reader service accounts default to no
mounted token. Source credentials, copies and reader grants remain separate native
objects so their ownership and permissions stay visible in values.

### Versioned database access

[database-access.yaml](examples/database-access.yaml) adds a small inline access
migration before the application's registry migration. It revokes public database
and schema access, grants runtime CONNECT/USAGE and sets SELECT/INSERT defaults
for tables created by the migration login in `public`. Both streams must use that
same login. The migrator inherits the
CNPG database owner's rights; the runtime is not a member of that owner. Passwords
remain Secret references. Existing service databases and roles are not adopted.

Use either `repository` + `tag`, or a `local` map of numbered SQL files for each
`postgres.migrations` entry. Inline files use native Atlas `template_dir`; `roleVars`
maps template names to roles already declared in `postgres.roles`. For example,
`"{{ .runtime }}"` in SQL receives the referenced role name, not its password.
Atlas renders and checksums the directory; Helm does not calculate `atlas.sum`.
Only trusted platform configuration may supply SQL. Keep large application
migration histories in the registry, rather than inline Kubernetes objects.

Set `schema: public` on both streams and give them different `revisionsSchema`
values outside `public`. The schema-scoped connection keeps Atlas's initial
cleanliness check on the application schema, while each private history stays
separate. This avoids `allow-dirty` and prevents default runtime table grants
from exposing either history. The schema must already exist (`public` does in a
new CNPG database). The chart rejects two streams sharing the same database/history.

Each migration can override the optional `syncWave`; otherwise it uses the
platform's `atlasMigration` wave. The example orders roles -> database -> access
migration -> application migration -> workloads. Current-generation Argo health
checks are required for that ordering to gate progress. HBA rules, password
Secrets, CA/RBAC and Atlas entitlement remain GitOps prerequisites; this example
does not deploy them or prove operator readiness.

For inline directories the chart also grants Atlas get/update on the exact
`io.atlasgo.db.v1.<resource-name>.latest` state Secret, plus Secret create in the
Atlas namespace. The operator always creates this state, even with downgrades
blocked. Kubernetes RBAC cannot restrict top-level create by resource name;
credential reads remain named-only, with no namespace-wide get/list/watch/update.
Registry-only releases do not receive these additional rules.

Access SQL is **append-only migration history**, not declarative permission
reconciliation. Never edit an applied file, change its roleVars or remove earlier
files. Atlas does not rerun edits to applied files or automatically correct grant
drift; append-only history needs review. Add a new numbered SQL file for each
grant/revoke change. Defaults affect
future tables only; revoking existing access also needs explicit REVOKE statements
on existing tables. Inline access downgrades are always blocked; use a reviewed
forward correction. Database deletion removes its grants/history, while SQL role
cleanup remains the separate ordered lifecycle described below.

Atlas's declarative permissions do not persist `ALTER DEFAULT PRIVILEGES` as a
managed object, so enabling permissions on the role resource would not establish
this access contract. The access migration owns these grants; the application
migration owns application objects and must not reconcile the same privileges.

Sources: [default privileges](https://atlasgo.io/guides/postgres/security-default-privileges),
[operator template-directory test](https://github.com/ariga/atlas-operator/blob/v0.8.4/test/e2e/testscript/migration-template-dir.txtar),
[migration history](https://atlasgo.io/integrations/kubernetes/versioned#revisionsschema),
[Kubernetes RBAC limits](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#referring-to-resources).

Database deletion defaults to `retain`; disposable previews explicitly choose
`delete`. Schema downgrades are blocked by default in `platform.atlas.migrateDown`.
Atlas role plans block destructive changes and use the configured review policy.
Removing a role from `roleScope` relinquishes management; it does not drop the
role. Keep the ownership scope while reconciling an empty desired role set for
an explicitly approved cleanup, after dropping its databases/dependencies.
Deleting Atlas CRs alone leaves SQL objects behind. PR-close orchestration and
backup/recovery drills remain separate implementation steps.
