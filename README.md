# Application chart

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

Argo CD sync wave annotations are absent by default. Set only the resource kinds
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

AtlasSchema owns the declared roles; AtlasMigration owns application schema and
its GRANT/REVOKE statements. The chart does not invent table privileges for the
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

Database deletion defaults to `retain`; disposable previews explicitly choose
`delete`. Schema downgrades are blocked by default in `platform.atlas.migrateDown`.
Atlas role plans block destructive changes and use the configured review policy.
Removing a role from `roleScope` relinquishes management; it does not drop the
role. Keep the ownership scope while reconciling an empty desired role set for
an explicitly approved cleanup, after dropping its databases/dependencies.
Deleting Atlas CRs alone leaves SQL objects behind. PR-close orchestration and
backup/recovery drills remain separate implementation steps.
