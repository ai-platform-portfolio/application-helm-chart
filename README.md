# Application chart

This chart lets an application describe its workloads without writing Kubernetes
manifests. Each entry in `components` creates a Deployment or Argo Rollout and
its Services. A component with a `route` also gets an HTTPRoute. Each entry in
`hosts` creates an HTTPS ListenerSet, certificate request and HTTP redirect.
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

The platform supplies the namespace and hosts in an environment values file.
The chart's `values.yaml` holds repeatable Gateway, resource and Rollout defaults;
templates set selectors, probes, pod security, stable/canary Services, route
weights and TLS attachment. The example Rollout promotes immediately. A later
delivery change will add measured steps and blocking tests.

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
