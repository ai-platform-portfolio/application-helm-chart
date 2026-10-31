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
    assert_includes error, 'hosts.public.hostname'
  end
end
