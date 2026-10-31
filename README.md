# Application resource chart

This chart renders reusable Kubernetes resource types. An application supplies
maps of resources in its values file; each map can contain any number of entries.
The chart has no built-in frontend, backend, service names or rollout strategy.

| Values map | Kubernetes kind |
| --- | --- |
| `namespaces` | Namespace |
| `deployments` | Deployment |
| `services` | Service |
| `rollouts` | Argo Rollout |
| `listenerSets` | Gateway API ListenerSet |
| `httpRoutes` | Gateway API HTTPRoute |

The map key is the resource name unless an entry sets `name`. Each namespaced
entry may set `namespace`; otherwise the chart uses the top-level `namespace`.
Entries may set `labels` and `annotations`. Their `spec` is the native Kubernetes
specification for that kind, so application-specific settings remain in the
application's values rather than becoming chart switches. The chart adds only
release labels to resource metadata. The top-level `hostname` fills an omitted
HTTPRoute `spec.hostnames` or ListenerSet listener `hostname`; an explicit value
on a resource takes precedence.

The ListenerSet and HTTPRoute templates share the same values convention, but
they remain separate maps. An application can create multiple listeners and
routes or use either kind independently.

## Example

`examples/application.yaml` defines the small frontend/API proof of concept.
Environment overlays supply its namespace and hostname:

```sh
helm template poc . -f examples/application.yaml -f examples/preview.yaml
helm template poc . -f examples/application.yaml -f examples/staging.yaml
helm template poc . -f examples/application.yaml -f examples/production.yaml
```

The example images and domains are placeholders. Use published image digests and
real hostnames for deployments. The example's Rollout uses the platform's
Gateway API plugin; its immediate promotion step leaves measured canary checks
for a later delivery change. Platform operators and the shared Gateway stay in
GitOps. Database and Atlas templates are separate follow-up work.

Run `ruby tests/render_test.rb` to lint and render all environments, verify the
frontend/API wiring, and prove multiple instances of every resource type render
without fixed names. The same test runs on pull requests.
