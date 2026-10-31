require 'minitest/autorun'
require 'open3'
require 'yaml'

class ChartRenderTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ENVIRONMENTS = {
    'preview' => ['preview-pr-42', 'pr-42.preview.example.com'],
    'staging' => ['poc-staging', 'poc.staging.example.com'],
    'production' => ['poc-production', 'poc.example.com']
  }.freeze

  def helm(*args)
    output, error, status = Open3.capture3('helm', *args, chdir: ROOT)
    assert status.success?, "helm #{args.join(' ')} failed:\n#{output}#{error}"
    output
  end

  def render(*files, extra: [])
    args = files.flat_map { |file| ['-f', file] }
    YAML.load_stream(helm('template', 'poc', '.', *args, *extra)).compact
  end

  def find(docs, kind, name)
    docs.find { |doc| doc['kind'] == kind && doc['metadata']['name'] == name }
  end

  def test_empty_chart_renders_no_resources
    assert_empty render
  end

  def test_small_application_values_render_each_environment
    ENVIRONMENTS.each do |environment, (namespace, hostname)|
      helm('lint', '.', '-f', 'examples/application.yaml', '-f', "examples/#{environment}.yaml")
      docs = render('examples/application.yaml', "examples/#{environment}.yaml")

      assert_equal 10, docs.length
      assert_equal namespace, find(docs, 'Namespace', namespace)['metadata']['name']
      assert docs.reject { |doc| doc['kind'] == 'Namespace' }
                 .all? { |doc| doc['metadata']['namespace'] == namespace }

      listener = find(docs, 'ListenerSet', 'public')
      assert_equal hostname, listener['spec']['listeners'].first['hostname']
      assert_equal 'letsencrypt-azuredns', listener['metadata']['annotations']['cert-manager.io/cluster-issuer']

      api_route = find(docs, 'HTTPRoute', 'backend')
      assert_equal [hostname], api_route['spec']['hostnames']
      refs = api_route['spec']['rules'].first['backendRefs']
      assert_equal %w[backend-stable backend-canary], refs.map { |ref| ref['name'] }
      assert_equal [100, 0], refs.map { |ref| ref['weight'] }

      frontend_route = find(docs, 'HTTPRoute', 'frontend')
      assert_equal '/', frontend_route['spec']['rules'].first['matches'].first['path']['value']
      assert_equal 'frontend', frontend_route['spec']['rules'].first['backendRefs'].first['name']
      redirect = find(docs, 'HTTPRoute', 'public-redirect')
      assert_equal [hostname], redirect['spec']['hostnames']
      assert_equal 'http', redirect['spec']['parentRefs'].first['sectionName']
      assert_equal 'https', redirect['spec']['rules'].first['filters'].first['requestRedirect']['scheme']

      frontend = find(docs, 'Deployment', 'frontend')
      assert_match(/@sha256:[0-9a-f]{64}\z/, frontend['spec']['template']['spec']['containers'].first['image'])
      assert_equal true, frontend['spec']['template']['spec']['containers'].first['securityContext']['readOnlyRootFilesystem']
      selector = find(docs, 'Service', 'frontend')['spec']['selector']
      assert selector.all? { |key, value| frontend['spec']['template']['metadata']['labels'][key] == value }

      rollout = find(docs, 'Rollout', 'backend')
      assert_equal 'backend', rollout['spec']['strategy']['canary']['trafficRouting']['plugins']['argoproj-labs/gatewayAPI']['httpRoute']
      assert_equal 'backend-stable', rollout['spec']['strategy']['canary']['stableService']
    end
  end

  def test_multiple_components_and_hosts_use_the_same_templates
    docs = render('examples/application.yaml', 'examples/preview.yaml', 'tests/fixtures/extra.yaml')
    counts = docs.group_by { |doc| doc['kind'] }.transform_values(&:length)

    assert_equal({ 'Namespace' => 1, 'Deployment' => 2, 'Service' => 6,
                   'Rollout' => 2, 'ListenerSet' => 2, 'HTTPRoute' => 5 }, counts)

    worker = find(docs, 'Deployment', 'worker')
    assert_equal 2, worker['spec']['replicas']
    assert_equal '250m', worker['spec']['template']['spec']['containers'].first['resources']['requests']['cpu']
    assert_equal '128Mi', worker['spec']['template']['spec']['containers'].first['resources']['requests']['memory']

    route = find(docs, 'HTTPRoute', 'processor')
    assert_equal ['internal.preview.example.com'], route['spec']['hostnames']
    assert_equal 'internal', route['spec']['parentRefs'].first['name']
    assert_nil find(docs, 'HTTPRoute', 'worker')
  end

  def test_another_application_can_render_without_poc_values
    docs = render('tests/fixtures/extra.yaml', extra: ['--set', 'namespace=another-app'])
    counts = docs.group_by { |doc| doc['kind'] }.transform_values(&:length)

    assert_equal({ 'Namespace' => 1, 'Deployment' => 1, 'Service' => 3,
                   'Rollout' => 1, 'ListenerSet' => 1, 'HTTPRoute' => 2 }, counts)
    assert_nil find(docs, 'Deployment', 'frontend')
    assert_equal 'another-app', find(docs, 'Service', 'processor-stable')['metadata']['namespace']
  end

  def test_redirect_defaults_on_and_can_be_disabled
    docs = render('examples/application.yaml', 'examples/preview.yaml',
                  'tests/fixtures/extra.yaml',
                  extra: ['--set', 'platform.pod.imagePullPolicy=Always'])

    assert_equal 5, docs.count { |doc| doc['kind'] == 'HTTPRoute' }
    assert_equal 'Always', find(docs, 'Deployment', 'frontend')['spec']['template']['spec']['containers'].first['imagePullPolicy']

    %w[public internal].each do |host|
      redirect = find(docs, 'HTTPRoute', "#{host}-redirect")
      assert_equal 301, redirect['spec']['rules'].first['filters'].first['requestRedirect']['statusCode']
    end

    without_redirect = render('examples/application.yaml', 'examples/preview.yaml',
                              'tests/fixtures/extra.yaml',
                              extra: ['--set', 'platform.gateway.httpRedirect.enabled=false'])
    assert_equal 3, without_redirect.count { |doc| doc['kind'] == 'HTTPRoute' }
    assert_nil find(without_redirect, 'HTTPRoute', 'public-redirect')
  end

  def test_extra_containers_and_optional_sync_waves
    docs = render('examples/application.yaml', 'examples/preview.yaml',
                  'tests/fixtures/containers.yaml')

    assert docs.all? { |doc| !doc.fetch('metadata', {}).fetch('annotations', {}).key?('argocd.argoproj.io/sync-wave') }

    %w[Deployment Rollout].zip(%w[frontend backend]).each do |kind, name|
      pod = find(docs, kind, name)['spec']['template']['spec']
      assert_equal 2, pod['containers'].length
      assert_equal 1, pod['initContainers'].length
      assert_equal true, pod['containers'].last['securityContext']['readOnlyRootFilesystem']
      assert_equal true, pod['initContainers'].first['securityContext']['readOnlyRootFilesystem']
    end

    frontend = find(docs, 'Deployment', 'frontend')['spec']['template']['spec']
    assert_equal 'telemetry', frontend['containers'].last['name']
    assert_equal 9090, frontend['containers'].last['ports'].first['containerPort']
    assert_equal '25m', frontend['containers'].last['resources']['requests']['cpu']
    assert_equal '128Mi', frontend['containers'].last['resources']['requests']['memory']
    assert_equal 'prepare', frontend['initContainers'].first['name']

    waves = { 'namespace' => -20, 'service' => -10, 'listenerSet' => -5,
              'deployment' => 0, 'rollout' => 1, 'httpRoute' => 2 }
    args = waves.flat_map { |kind, wave| ['--set', "platform.syncWaves.#{kind}=#{wave}"] }
    with_waves = render('examples/application.yaml', 'examples/preview.yaml', extra: args)
    kinds = { 'Namespace' => 'namespace', 'Deployment' => 'deployment',
              'Service' => 'service', 'Rollout' => 'rollout',
              'ListenerSet' => 'listenerSet', 'HTTPRoute' => 'httpRoute' }

    with_waves.each do |doc|
      assert_equal waves[kinds.fetch(doc['kind'])].to_s,
                   doc['metadata']['annotations']['argocd.argoproj.io/sync-wave']
    end
  end

  def test_optional_azure_identities_roles_and_private_containers
    args = ['--set', 'platform.azure.subscriptionId=example-subscription',
            '--set', 'platform.azure.tenantId=example-tenant']
    docs = render('examples/application.yaml', 'examples/preview.yaml',
                  'tests/fixtures/azure.yaml', extra: args)
    counts = docs.group_by { |doc| doc['kind'] }.transform_values(&:length)

    assert_equal 2, counts['UserAssignedIdentity']
    assert_equal 2, counts['FederatedIdentityCredential']
    assert_equal 2, counts['ServiceAccount']
    assert_equal 2, counts['RoleAssignment']
    assert_equal 2, counts['StorageAccountsBlobServicesContainer']

    identity = docs.find { |doc| doc['kind'] == 'UserAssignedIdentity' && doc['spec']['azureName'] == 'id-example-backend' }
    identity_name = identity['metadata']['name']
    assert_equal 'azure-resources', identity['metadata']['namespace']
    assert_equal '/subscriptions/example-subscription/resourceGroups/example-identities', identity['spec']['owner']['armId']
    client = identity['spec']['operatorSpec']['configMaps']['clientId']
    assert_equal "#{identity_name}-client-id", client['name']
    refute client.key?('annotations')
    assert_equal "#{identity_name}-principal-id", identity['spec']['operatorSpec']['configMaps']['principalId']['name']
    refute identity['spec']['operatorSpec']['configMaps']['principalId'].key?('annotations')
    credential = find(docs, 'FederatedIdentityCredential', identity_name)
    assert_equal 'system:serviceaccount:preview-pr-42:backend', credential['spec']['subject']
    assert_equal identity_name, credential['spec']['owner']['name']

    roles = docs.select { |doc| doc['kind'] == 'RoleAssignment' }
    assert_equal %w[Key\ Vault\ Secrets\ User Storage\ Blob\ Data\ Reader].sort,
                 roles.map { |role| role['spec']['roleDefinitionReference']['wellKnownName'] }.sort
    assert roles.all? { |role| role['spec']['principalIdFromConfig']['name'] == "#{identity_name}-principal-id" }
    assert roles.all? { |role| role['spec']['azureName'].match?(/\A[0-9a-f-]{36}\z/) }
    assert_equal [
      '/subscriptions/example-subscription/resourceGroups/example-platform/providers/Microsoft.KeyVault/vaults/example-vault',
      '/subscriptions/example-subscription/resourceGroups/example-platform/providers/Microsoft.Storage/storageAccounts/examplestorage'
    ], roles.map { |role| role['spec']['owner']['armId'] }.sort

    container = docs.find { |doc| doc['kind'] == 'StorageAccountsBlobServicesContainer' && doc['spec']['azureName'] == 'example-app-files' }
    assert_equal 'None', container['spec']['publicAccess']
    assert_equal '/subscriptions/example-subscription/resourceGroups/example-platform/providers/Microsoft.Storage/storageAccounts/examplestorage/blobServices/default', container['spec']['owner']['armId']

    %w[Deployment Rollout].zip(%w[frontend backend]).each do |kind, name|
      pod = find(docs, kind, name)['spec']['template']['spec']
      assert_equal name, pod['serviceAccountName']
      assert_equal false, pod['automountServiceAccountToken']
      account = find(docs, 'ServiceAccount', name)
      assert_equal 'true', find(docs, kind, name)['spec']['template']['metadata']['labels']['azure.workload.identity/use']
      assert_match(/00000000-0000-0000-0000-00000000000[12]/, account['metadata']['annotations']['azure.workload.identity/client-id'])
      refute pod['containers'].first.key?('env')
      refute pod['volumes'].any? { |volume| volume.key?('projected') }
    end

    backend = find(docs, 'Rollout', 'backend')['spec']['template']['spec']
    refute backend['containers'].last.key?('env')
    refute backend['initContainers'].first.key?('volumeMounts')
    refute backend['containers'].last.key?('azureIdentity')

    azure_kinds = %w[UserAssignedIdentity FederatedIdentityCredential ServiceAccount RoleAssignment StorageAccountsBlobServicesContainer]
    assert docs.select { |doc| azure_kinds.include?(doc['kind']) }
               .all? { |doc| !doc.fetch('metadata', {}).fetch('annotations', {}).key?('argocd.argoproj.io/sync-wave') }
    assert docs.select { |doc| azure_kinds.include?(doc['kind']) && doc['kind'] != 'ServiceAccount' }
               .all? { |doc| doc['metadata']['namespace'] == 'azure-resources' }
    assert_equal docs.map { |doc| [doc['kind'], doc['metadata']['namespace'], doc['metadata']['name']] }.uniq.length, docs.length
    assert docs.all? { |doc| doc['metadata']['name'].length <= 63 }

    args += ['--set', 'platform.syncWaves.userAssignedIdentity=0',
             '--set', 'platform.syncWaves.roleAssignment=10',
             '--set', 'platform.syncWaves.storageContainer=5']
    with_waves = render('examples/application.yaml', 'examples/preview.yaml',
                        'tests/fixtures/azure.yaml', extra: args)
    assert_equal '0', find(with_waves, 'UserAssignedIdentity', identity_name)['metadata']['annotations']['argocd.argoproj.io/sync-wave']
    assert_equal '10', with_waves.find { |doc| doc['kind'] == 'RoleAssignment' }['metadata']['annotations']['argocd.argoproj.io/sync-wave']
    assert_equal '5', with_waves.find { |doc| doc['kind'] == 'StorageAccountsBlobServicesContainer' }['metadata']['annotations']['argocd.argoproj.io/sync-wave']
  end

  def test_shared_preview_identity_creates_only_a_federated_credential
    args = ['--set', 'platform.azure.identities.shared.azureName=id-shared-preview',
            '--set', 'platform.azure.identities.shared.create=false',
            '--set', 'platform.azure.identities.shared.clientId=00000000-0000-0000-0000-000000000003',
            '--set', 'platform.azure.identityResourceGroup=rg-preview',
            '--set', 'platform.azure.subscriptionId=example-subscription',
            '--set', 'platform.azure.tenantId=example-tenant',
            '--set', 'platform.azure.oidcIssuerUrl=https://issuer.example.invalid/',
            '--set', 'components.backend.identity=shared']
    docs = render('examples/application.yaml', 'examples/preview.yaml', 'tests/fixtures/containers.yaml', extra: args)

    refute docs.any? { |doc| doc['kind'] == 'UserAssignedIdentity' || doc['kind'] == 'RoleAssignment' }
    annotations = find(docs, 'Rollout', 'backend')['spec']['template']['metadata']['annotations']
    assert_equal %w[configure metrics], annotations['azure.workload.identity/skip-containers'].split(';').sort
    credential = docs.find { |doc| doc['kind'] == 'FederatedIdentityCredential' }
    assert_equal 'azure-resources', credential['metadata']['namespace']
    assert_equal 'system:serviceaccount:preview-pr-42:shared', credential['spec']['subject']
    assert_equal '/subscriptions/example-subscription/resourceGroups/rg-preview/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-shared-preview', credential['spec']['owner']['armId']
    assert_equal '00000000-0000-0000-0000-000000000003', find(docs, 'ServiceAccount', 'shared')['metadata']['annotations']['azure.workload.identity/client-id']

    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
      '-f', 'examples/application.yaml', '-f', 'examples/preview.yaml',
      *args, '--set', 'platform.azure.identities.shared.storageBlobDataReader=true', chdir: ROOT)
    refute status.success?
    assert_includes error, 'assign its roles once in platform GitOps'
  end

  def test_identity_provisioning_precedes_workload_client_id
    args = ['--set', 'namespace=identity-stage',
            '--set', 'platform.azure.identities.backend.azureName=id-example-backend',
            '--set', 'platform.azure.location=example-region',
            '--set', 'platform.azure.subscriptionId=example-subscription',
            '--set', 'platform.azure.identityResourceGroup=example-platform',
            '--set', 'platform.azure.oidcIssuerUrl=https://issuer.example.invalid/']
    docs = render(extra: args)
    assert docs.any? { |doc| doc['kind'] == 'UserAssignedIdentity' }
    refute docs.any? { |doc| doc['kind'] == 'ServiceAccount' }

    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
      '-f', 'examples/application.yaml', *args,
      '--set', 'components.backend.identity=backend', chdir: ROOT)
    refute status.success?
    assert_includes error, 'needs clientId before deploying workloads'
  end

  def test_undefined_identity_is_rejected
    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml',
                                            '-f', 'examples/preview.yaml',
                                            '--set', 'components.frontend.identity=missing', chdir: ROOT)
    refute status.success?
    assert_includes error, 'references undefined identity missing'
  end

  def test_missing_namespace_and_mutable_image_are_rejected
    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml',
                                            '-f', 'examples/preview.yaml',
                                            '--set', 'namespace=', chdir: ROOT)
    refute status.success?
    assert_includes error, 'namespace is required'

    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml',
                                            '-f', 'examples/preview.yaml',
                                            '--set', 'components.frontend.image=frontend:latest', chdir: ROOT)
    refute status.success?
    assert_match(/frontend(?:\/|\.)image/, error)

    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml',
                                            '-f', 'examples/preview.yaml',
                                            '--set', 'hosts.public.hostname=*.preview.example.com', chdir: ROOT)
    refute status.success?
    assert_match(%r{(?:hosts\.public\.hostname|/hosts/public/hostname)}, error)

    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml',
                                            '-f', 'examples/preview.yaml',
                                            '-f', 'tests/fixtures/containers.yaml',
                                            '--set', 'components.frontend.sidecars.telemetry.image=telemetry:latest', chdir: ROOT)
    refute status.success?
    assert_match(/telemetry(?:\/|\.)image/, error)
  end
end
