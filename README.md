# Application Helm chart

Shared deployment contract for the portfolio's small frontend and Python API.
The chart renders a namespace, frontend Deployment, backend Argo Rollout,
Services, an HTTPS ListenerSet and Gateway API HTTPRoutes. Platform operators
and the shared Gateway are installed separately through GitOps. Cert-manager
issues the per-host certificate from the ListenerSet issuer annotation.

The backend route starts with 100% stable and 0% canary traffic. The Rollout uses
the installed `argoproj-labs/gatewayAPI` plugin, with an immediate promotion step.
Measured canary steps and blocking tests are added with the delivery workflow.
The chart requires immutable image digests to align promoted artifacts across
environments.

## Render examples

```sh
helm lint . -f examples/preview.yaml
helm template preview-pr-42 . -f examples/preview.yaml

helm lint . -f examples/staging.yaml
helm template sample-staging . -f examples/staging.yaml

helm lint . -f examples/production.yaml
helm template sample-production . -f examples/production.yaml
```

The example hostnames and image digests are placeholders for render checks.
Deployments must set real hosts and published FE/BE image digests. Each HTTPS
HTTPRoute attaches to the application-owned ListenerSet named `public` in the
application namespace. The HTTP redirect route attaches to the shared public
Gateway in `envoy-gateway-system`.

Database provisioning, credentials and Atlas migrations are added as separate
chart changes after their lifecycle is agreed. The chart is not deployed by
this repository's first PR.
