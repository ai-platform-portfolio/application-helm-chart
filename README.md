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

`keyVaultSecretsUser` and `storageBlobDataReader` are optional role assignments
for newly created identities. Their scopes are the whole existing vault and
storage account, respectively; do not enable them for disposable previews.
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

Run `ruby tests/render_test.rb` for the automated render checks. The same test
runs on pull requests.
