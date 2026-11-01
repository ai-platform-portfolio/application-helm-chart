#!/bin/sh
# Exercise ordering/failure boundaries without touching a cluster.
set -eu
chart=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
state=$(mktemp -d)
trap 'status=$?; if [ "$status" -ne 0 ]; then cat "$state/output" 2>/dev/null || true; fi; rm -rf "$state"' EXIT
export TEST_STATE="$state" CLEANUP_ATTEMPT=test-pod
mkdir "$state/bin"
export PATH="$state/bin:$PATH"
export CLEANUP_CONFIG='{"namespace":"app","release":"test","atlasNamespace":"atlas","postgresNamespace":"postgres","schema":"roles","roleConfig":"exact scoped config","roleEnvironment":"roles","roleConnection":{"secretKeyRef":{"name":"shared-connection","key":"url"}},"databases":{"db":{"name":"app_db","owner":"owner","cluster":{"name":"platform"},"databaseReclaimPolicy":"delete"}},"workloads":{"api":"deployments.apps"},"migrations":["migration"],"connections":["connection"],"clients":["client"],"states":["directory-state"]}'

cat > "$state/bin/kubectl" <<'SH'
#!/bin/sh
set -eu
shift # --request-timeout
[ "$1" = -n ]; ns=$2; shift 2
verb=$1; kind=$2; name=$3; shift 3
printf '%s %s %s %s\n' "$verb" "$ns" "$kind" "$name" >> "$TEST_STATE/log"
file="$TEST_STATE/$kind-$name"
case $verb in
  get)
    if [ "$kind" = pods ] && [ -f "$TEST_STATE/api-error" ]; then exit 1; fi
    if [ "$kind" = atlasmigrations.db.atlasgo.io ] && [ -f "$TEST_STATE/api-error" ]; then exit 1; fi
    if [ "$kind" = pods ]; then
      if [ -f "$TEST_STATE/pods" ]; then
        printf '{"items":[{}]}'
        rm "$TEST_STATE/pods"
      else printf '{"items":[]}'; fi
    elif [ -f "$file" ]; then
      if [ "$kind" = atlasschemas.db.atlasgo.io ] && [ -f "$TEST_STATE/patched" ] && [ ! -f "$TEST_STATE/stale" ]; then
        jq '.status.conditions[0].observedGeneration = .metadata.generation' "$file" > "$file.next"
        mv "$file.next" "$file"
      fi
      cat "$file"
    fi
    ;;
  delete)
    if [ "$kind" = databases.postgresql.cnpg.io ] && [ -f "$TEST_STATE/blocked" ]; then exit 0; fi
    rm -f "$file"
    ;;
  patch)
    if [ "$kind" = atlasschemas.db.atlasgo.io ]; then
      [ ! -f "$TEST_STATE/databases.postgresql.cnpg.io-db" ]
      for arg in "$@"; do case "$arg" in --patch-file=*) patch=${arg#*=};; esac; done
      jq --slurpfile patch "$patch" '
        .spec.schema.hcl = $patch[0][3].value |
        .metadata.generation += 1 |
        .status.conditions = [{type:"Ready",status:"True",observedGeneration:(.metadata.generation - 1)}]' "$file" > "$file.next"
      mv "$file.next" "$file"
      touch "$TEST_STATE/patched"
      cat "$file"
    fi
    ;;
  *) exit 99;;
esac
SH
cat > "$state/bin/sleep" <<'SH'
#!/bin/sh
printf 'wait\n' >> "$TEST_STATE/log"
# Simulate the Job deadline, without waiting minutes in CI.
if [ -f "$TEST_STATE/blocked" ] || [ -f "$TEST_STATE/stale" ]; then exit 77; fi
SH
chmod +x "$state/bin/kubectl" "$state/bin/sleep"

reset() {
  rm -f "$state"/* 2>/dev/null || true
  printf '%s' "$CLEANUP_CONFIG" | jq '{spec:.databases.db,metadata:{finalizers:["cnpg.io/deleteDatabase"]}}' > "$state/databases.postgresql.cnpg.io-db"
  printf '%s' "$CLEANUP_CONFIG" | jq '{spec:{config:.roleConfig,envName:.roleEnvironment,urlFrom:.roleConnection,schema:{hcl:"original roles"}},metadata:{uid:"stable",generation:1}}' > "$state/atlasschemas.db.atlasgo.io-roles"
  printf '{"metadata":{"labels":{"app.kubernetes.io/instance":"test","app.kubernetes.io/component":"api"}}}' > "$state/deployments.apps-api"
  for object in atlasmigrations.db.atlasgo.io-migration certificates.cert-manager.io-client externalsecrets.external-secrets.io-connection secret-client secret-connection secret-directory-state; do
    printf '{}' > "$state/$object"
  done
  : > "$state/log"
}
run() { sh "$chart/files/lifecycle/cleanup.sh" > "$state/output" 2>&1; }
unchanged() { ! grep -E '^(patch|delete) ' "$state/log" >/dev/null; }
fails() { if run; then cat "$state/log"; echo 'Expected cleanup to fail' >&2; exit 1; fi; }

reset
touch "$state/pods"
run
awk '
  /^patch app/ {stop=NR}
  /^delete atlas atlasmigrations/ {migration=NR}
  /^delete postgres databases/ {database=NR}
  /^patch atlas atlasschemas/ {roles=NR}
  /^delete postgres certificates/ {certificate=NR}
  END {exit !(stop < migration && migration < database && database < roles && roles < certificate)}' "$state/log"
[ ! -f "$state/secret-client" ]
[ ! -f "$state/secret-directory-state" ]
run # Repeated deletion tolerates absent resources.
echo 'PASS: ordered cleanup, pod drain and repeated execution'

reset
jq '.spec.databaseReclaimPolicy = "retain"' "$state/databases.postgresql.cnpg.io-db" > "$state/edit"
mv "$state/edit" "$state/databases.postgresql.cnpg.io-db"
fails; unchanged
echo 'PASS: retained database fails before mutations'

reset
jq '.spec.config = "unscoped"' "$state/atlasschemas.db.atlasgo.io-roles" > "$state/edit"
mv "$state/edit" "$state/atlasschemas.db.atlasgo.io-roles"
fails; unchanged
echo 'PASS: ownership mismatch fails before mutations'

reset
rm "$state/atlasschemas.db.atlasgo.io-roles"
fails; unchanged
echo 'PASS: existing database with missing role reconciler blocks deletion'

reset
rm "$state/atlasschemas.db.atlasgo.io-roles" "$state/databases.postgresql.cnpg.io-db"
run
! grep -E ' app ' "$state/log" >/dev/null
echo 'PASS: never-provisioned deployment needs no application namespace access'

reset
touch "$state/blocked"
fails
! grep -E '^patch atlas|^delete postgres certificates' "$state/log" >/dev/null
rm "$state/blocked"
run
echo 'PASS: database finalization blocks role deletion; retry resumes cleanup'

reset
touch "$state/stale"
fails
[ -f "$state/certificates.cert-manager.io-client" ]
[ -f "$state/secret-directory-state" ]
rm "$state/stale"
run
echo 'PASS: stale Ready cannot release credentials; retry resumes reconciliation'

reset
touch "$state/api-error"
fails
! grep -E '^delete ' "$state/log" >/dev/null
rm "$state/deployments.apps-api"
export CLEANUP_CONFIG=$(printf '%s' "$CLEANUP_CONFIG" | jq '.workloads = {}')
fails
! grep -E '^delete postgres databases|^patch atlas' "$state/log" >/dev/null
echo 'PASS: pod-list and deletion-poll API errors cannot masquerade as absence'
