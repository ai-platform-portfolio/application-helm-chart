#!/bin/sh
# Argo PreDelete: only Kubernetes API calls, never SQL or database credentials.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s' "$CLEANUP_CONFIG" > "$work/config.json"
config="$work/config.json"
app=$(jq -r .namespace "$config")
atlas=$(jq -r .atlasNamespace "$config")
postgres=$(jq -r .postgresNamespace "$config")
schema=$(jq -r .schema "$config")
release=$(jq -r .release "$config")
fail() { echo "$*" >&2; exit 1; }

# Per-request deadlines bound API outages; the Job deadline bounds all polling.
k() { kubectl --request-timeout=20s "$@"; }
get() { k -n "$1" get "$2" "$3" --ignore-not-found -o json; }
gone() {
  while :; do
    live=$(get "$1" "$2" "$3")
    [ -n "$live" ] || break
    sleep 2
  done
}
remove() {
  k -n "$1" delete "$2" "$3" --ignore-not-found --wait=false
  gone "$1" "$2" "$3"
}

# Validate all live databases before making any changes. Never override retain.
for name in $(jq -r '.databases | keys[]' "$config"); do
  live=$(get "$postgres" databases.postgresql.cnpg.io "$name")
  if [ -n "$live" ]; then
    printf '%s' "$live" | jq -e --arg name "$name" --slurpfile expected "$config" '
      .spec as $actual | $expected[0].databases[$name] | to_entries |
      all(.[]; $actual[.key] == .value)' >/dev/null || fail "Refusing cleanup: database $name identity or deletion policy changed."
  fi
done
roles=$(get "$atlas" atlasschemas.db.atlasgo.io "$schema")

if [ -n "$roles" ]; then
  printf '%s' "$roles" | jq -e --slurpfile expected "$config" '
    .spec.config == $expected[0].roleConfig and
    .spec.envName == $expected[0].roleEnvironment and
    .spec.urlFrom == $expected[0].roleConnection' >/dev/null || fail "Refusing cleanup: Atlas resource $schema ownership scope or connection changed."
  # This access was synced before any SQL resource. A failed initial sync can
  # have no role resource yet; in that case there are no DB-backed workloads.
  for name in $(jq -r '.workloads | keys[]' "$config"); do
    kind=$(jq -r --arg name "$name" '.workloads[$name]' "$config")
    live=$(get "$app" "$kind" "$name")
    if [ -n "$live" ]; then
      printf '%s' "$live" | jq -e --arg release "$release" --arg name "$name" '
        .metadata.labels["app.kubernetes.io/instance"] == $release and
        .metadata.labels["app.kubernetes.io/component"] == $name' >/dev/null || fail "Refusing cleanup: workload $name belongs to another application."
      k -n "$app" patch "$kind" "$name" --type=merge -p '{"spec":{"replicas":0}}'
    fi
    while :; do
      pods=$(k -n "$app" get pods -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=$name" -o json)
      count=$(printf '%s' "$pods" | jq -e '.items | length')
      [ "$count" -ne 0 ] || break
      sleep 2
    done
  done
else
  # With chart-ordered sync, missing roles + missing DBs means never provisioned
  # (or already cleaned). A DB without its role reconciler is unsafe to infer.
  for name in $(jq -r '.databases | keys[]' "$config"); do
    live=$(get "$postgres" databases.postgresql.cnpg.io "$name")
    [ -z "$live" ] || {
      echo 'Refusing cleanup: database exists without its Atlas role resource.' >&2
      exit 1
    }
  done
fi

for name in $(jq -r '.migrations[]' "$config"); do
  remove "$atlas" atlasmigrations.db.atlasgo.io "$name"
done
for name in $(jq -r '.databases | keys[]' "$config"); do
  # CNPG must install its SQL-deletion finalizer before the CR can be removed.
  while :; do
    live=$(get "$postgres" databases.postgresql.cnpg.io "$name")
    [ -n "$live" ] || break
    if printf '%s' "$live" | jq -e '.metadata.finalizers | index("cnpg.io/deleteDatabase") != null' >/dev/null; then break; fi
    sleep 2
  done
  remove "$postgres" databases.postgresql.cnpg.io "$name"
done

if [ -n "$roles" ]; then
  # JSON Patch tests keep the exact ownership scope and connection in place.
  # Never weaken review/lint policy: DROP ROLE is not reliably lint-gated.
  # A new Pod UID changes only a comment, allowing Atlas to retry a failed apply.
  jq --arg attempt "$CLEANUP_ATTEMPT" '[
    {op:"test",path:"/spec/config",value:.roleConfig},
    {op:"test",path:"/spec/envName",value:.roleEnvironment},
    {op:"test",path:"/spec/urlFrom",value:.roleConnection},
    {op:"add",path:"/spec/schema/hcl",value:("// Empty desired role state; keep the exact ownership include scope above.\n// Cleanup attempt: " + $attempt + "\n")}
  ]' "$config" > "$work/patch.json"
  k -n "$atlas" patch atlasschemas.db.atlasgo.io "$schema" --type=json --patch-file="$work/patch.json" -o json > "$work/roles.json"
  uid=$(jq -r .metadata.uid "$work/roles.json")
  generation=$(jq .metadata.generation "$work/roles.json")
  while :; do
    get "$atlas" atlasschemas.db.atlasgo.io "$schema" > "$work/roles.json"
    jq -e --arg uid "$uid" --argjson generation "$generation" '
      .metadata.uid == $uid and .metadata.generation == $generation' "$work/roles.json" >/dev/null || fail "Refusing cleanup: Atlas resource $schema was replaced or changed during cleanup."
    if jq -e --argjson generation "$generation" '
      any(.status.conditions[]?; .type == "Ready" and .status == "True" and .observedGeneration == $generation)' "$work/roles.json" >/dev/null; then break; fi
    sleep 2
  done
fi

# Delete producers before Secrets so controllers cannot recreate credentials.
# No role resource also means no application cleanup RBAC may have synced yet.
if [ -n "$roles" ]; then
  for name in $(jq -r '.connections[]' "$config"); do
    remove "$app" externalsecrets.external-secrets.io "$name"
    k -n "$app" delete secret "$name" --ignore-not-found --wait=false
  done
fi
for name in $(jq -r '.clients[]' "$config"); do
  remove "$postgres" certificates.cert-manager.io "$name"
  k -n "$postgres" delete secret "$name" --ignore-not-found --wait=false
done
for name in $(jq -r '.states[]' "$config"); do
  k -n "$atlas" delete secret "$name" --ignore-not-found --wait=false
done
echo 'Owned SQL resources and credentials cleaned; Argo may finish application deletion.'
