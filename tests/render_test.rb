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

  def render(*files)
    args = files.flat_map { |file| ['-f', file] }
    YAML.load_stream(helm('template', 'poc', '.', *args)).compact
  end

  def find(docs, kind, name)
    docs.find { |doc| doc['kind'] == kind && doc['metadata']['name'] == name }
  end

  def test_empty_chart_renders_no_resources
    assert_empty render
  end

  def test_example_environments
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

      rollout = find(docs, 'Rollout', 'backend')
      assert_equal 'backend', rollout['spec']['strategy']['canary']['trafficRouting']['plugins']['argoproj-labs/gatewayAPI']['httpRoute']
      assert_equal 'backend-stable', rollout['spec']['strategy']['canary']['stableService']
    end
  end

  def test_resource_maps_support_additional_instances_and_overrides
    docs = render('examples/application.yaml', 'examples/preview.yaml', 'tests/fixtures/extra.yaml')
    counts = docs.group_by { |doc| doc['kind'] }.transform_values(&:length)

    assert_equal({ 'Namespace' => 2, 'Deployment' => 2, 'Service' => 4,
                   'Rollout' => 2, 'ListenerSet' => 2, 'HTTPRoute' => 4 }, counts)

    worker = find(docs, 'Deployment', 'worker')
    assert_equal 'auxiliary', worker['metadata']['namespace']
    assert_equal 'worker-team', worker['metadata']['annotations']['example.test/owner']
    assert_equal 2, worker['spec']['replicas']

    steps = find(docs, 'Rollout', 'processor')['spec']['strategy']['canary']['steps']
    assert_equal [{ 'setWeight' => 50 }, { 'pause' => {} }], steps

    route = find(docs, 'HTTPRoute', 'worker')
    assert_equal ['worker.example.com'], route['spec']['hostnames']
    assert_equal 'auxiliary', route['metadata']['namespace']
  end

  def test_another_application_can_render_without_poc_values
    docs = render('tests/fixtures/extra.yaml')
    counts = docs.group_by { |doc| doc['kind'] }.transform_values(&:length)

    assert_equal({ 'Namespace' => 1, 'Deployment' => 1, 'Service' => 1,
                   'Rollout' => 1, 'ListenerSet' => 1, 'HTTPRoute' => 1 }, counts)
    assert_equal 'auxiliary', find(docs, 'Service', 'worker')['metadata']['namespace']
    refute find(docs, 'Service', 'frontend')
  end

  def test_namespaced_resource_requires_namespace
    _output, error, status = Open3.capture3('helm', 'template', 'poc', '.',
                                            '-f', 'examples/application.yaml', chdir: ROOT)
    refute status.success?
    assert_includes error, 'namespace is required'
  end
end
