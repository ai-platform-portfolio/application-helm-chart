"""Exercise ownership, retry windows and spend-preserving rotation with native API shapes."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
import subprocess
import tempfile
import yaml


spec = importlib.util.spec_from_file_location('gateway_access', Path(__file__).parents[1] / 'files/gateway-access.py')
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class Missing(Exception):
    status_code = 404


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 16, tzinfo=timezone.utc)
        self.secrets, self.keys, self.users, self.calls = {}, {}, {}, []
        self.fail_after_create = False
        self.config = {'name': 'consumer-one', 'identity': 'org/repo/pr-1/worker',
                       'policy': {'maxBudget': 1, 'budgetDuration': '30d', 'rpm': 10, 'tpm': 1000,
                                  'parallel': 2, 'capabilities': {'default': {
                                      'model': 'chat', 'routes': ['/v1/chat/completions'],
                                      'rpm': 10, 'tpm': 1000, 'parallel': 2}}}}
        self.vault = SimpleNamespace(get_secret=self.read, set_secret=self.write)
        self.manager = gateway.Manager(self.config, self.api, self.vault, lambda: self.now)

    def read(self, name):
        if name not in self.secrets:
            raise Missing()
        return SimpleNamespace(value=self.secrets[name][0])

    def write(self, name, value, **options):
        self.secrets[name] = (value, options)

    def api(self, method, path, **arguments):
        data = arguments.get('json', {})
        self.calls.append((method, path, copy.deepcopy(data)))
        if path == '/user/info':
            return {'user_info': copy.deepcopy(self.users.get(arguments['params']['user_id']))}
        if path == '/user/new':
            self.users[data['user_id']] = {**data, 'spend': 0, 'budget_reset_at': 'original-reset'}
        elif path == '/user/update':
            self.users[data['user_id']].update(data)
        elif path == '/v2/key/info':
            return {'info': [copy.deepcopy(self.keys[key]) for key in data['keys'] if key in self.keys]}
        elif path == '/key/generate':
            expires = self.now + timedelta(seconds=int(data['duration'][:-1]))
            self.keys[data['key']] = {**data, 'team_id': None, 'expires': expires.isoformat()}
            if self.fail_after_create:
                self.fail_after_create = False
                raise RuntimeError('lost acknowledgement')
        elif path == '/key/delete':
            for key in data['keys']:
                self.keys.pop(key)
        else:
            raise AssertionError(path)
        return {}

    def test_rotation_reuses_owner_spend_reset_and_keeps_keys_finite(self):
        self.manager.reconcile()
        owner = self.manager.owner
        self.users[owner]['spend'] = 0.6
        original = self.secrets['consumer-one-default'][0]
        self.manager.reconcile()
        self.assertEqual(self.secrets['consumer-one-default'][0], original)
        self.now += timedelta(hours=25)
        self.manager.reconcile()
        self.assertNotEqual(self.secrets['consumer-one-default'][0], original)
        self.assertEqual(self.users[owner]['spend'], 0.6)
        self.assertEqual(self.users[owner]['budget_reset_at'], 'original-reset')
        self.assertEqual(len(self.users), 1)
        self.assertEqual(len(self.keys), 2)
        self.now += timedelta(hours=24)
        self.manager.reconcile()
        self.assertNotIn(original, self.keys)
        self.assertTrue(all(key['allowed_routes'] == ['/v1/chat/completions'] for key in self.keys.values()))

    def test_lost_create_ack_retries_same_saved_generation(self):
        self.fail_after_create = True
        with self.assertRaises(RuntimeError):
            self.manager.reconcile()
        saved = json.loads(self.secrets['consumer-one-control'][0])['keys'][0]['key']
        self.manager.reconcile()
        self.assertEqual(self.secrets['consumer-one-default'][0], saved)
        self.assertEqual(len([c for c in self.calls if c[1] == '/key/generate']), 1)

    def test_missing_accounting_and_cross_owner_control_fail_closed(self):
        self.manager.reconcile()
        self.users.clear()
        with self.assertRaises(ValueError):
            self.manager.reconcile()
        changed = {**self.config, 'identity': 'another/repo/pr-1/worker'}
        with self.assertRaises(ValueError):
            gateway.Manager(changed, self.api, self.vault, lambda: self.now).reconcile()

    def test_revoke_removes_keys_disables_secret_but_preserves_accounting(self):
        self.manager.reconcile()
        self.users[self.manager.owner]['spend'] = 0.4
        self.manager.reconcile(delete=True)
        self.assertEqual(self.keys, {})
        self.assertFalse(self.secrets['consumer-one-default'][1]['enabled'])
        self.assertEqual(self.users[self.manager.owner]['spend'], 0.4)

    def test_unset_budget_or_management_route_cannot_issue(self):
        for change in [{'maxBudget': None}, {'maxBudget': float('inf')},
                       {'capabilities': {'default': {'model': '*', 'routes': ['/key/generate']}}}]:
            with self.assertRaises(ValueError):
                gateway.validate({**self.config, 'policy': {**self.config['policy'], **change}})
        self.assertEqual(self.calls, [])


class RenderingTests(unittest.TestCase):
    def test_publication_lint_without_environment_metadata(self):
        intent = {'name': 'example', 'components': {'worker': {
            'image': 'example/image@sha256:' + 'a' * 64,
            'command': ['python'], 'gatewayAccess': {'policy': 'documents'}}}}
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as source:
            json.dump(intent, source)
            source.flush()
            result = subprocess.run(['helm', 'lint', str(Path(__file__).parents[1]), '-f', source.name],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # Actual deployment must still reject missing trusted policy metadata.
            result = subprocess.run(['helm', 'template', 'example', str(Path(__file__).parents[1]), '-f', source.name],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Gateway policy is not configured', result.stderr)

    def render(self, namespace, consumer='org/repo'):
        policy = {'maxBudget': 1, 'budgetDuration': '30d', 'rpm': 10, 'tpm': 1000, 'parallel': 2,
                  'capabilities': {'default': {'model': 'reasoning', 'routes': ['/v1/chat/completions'],
                                              'rpm': 10, 'tpm': 1000, 'parallel': 2}}}
        values = {'name': 'example', 'namespace': namespace,
                  'components': {'worker': {'command': ['python'], 'image': 'example/image@sha256:' + 'a' * 64,
                                            'gatewayAccess': {'policy': 'documents'}}},
                  'platform': {'azure': {'subscriptionId': '00000000-0000-0000-0000-000000000001',
                                        'tenantId': '00000000-0000-0000-0000-000000000002',
                                        'oidcIssuerUrl': 'https://issuer.example/', 'location': 'uksouth',
                                        'identityResourceGroup': 'platform', 'keyVault': {'name': 'example', 'resourceGroup': 'platform'}},
                               'modelGateway': {'consumerIdentity': consumer, 'endpoint': 'https://models.internal.example/v1',
                                                'vaultUri': 'https://example.vault.azure.net', 'masterSecret': 'platform-master',
                                                'policies': {'documents': policy}}}}
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as source:
            json.dump(values, source)
            source.flush()
            result = subprocess.run(['helm', 'template', 'example', str(Path(__file__).parents[1]), '-f', source.name],
                                    capture_output=True, text=True, check=True)
        return [item for item in yaml.safe_load_all(result.stdout) if item]

    def test_component_uses_own_identity_without_a_direct_model_grant(self):
        items = self.render('repo-one-pr-1')
        deployment = next(item for item in items if item['kind'] == 'Deployment')
        pod = deployment['spec']['template']['spec']
        self.assertEqual(pod['serviceAccountName'], 'worker-runtime')
        env = {entry['name']: entry.get('value') for entry in pod['containers'][0]['env']}
        self.assertEqual(env['MODEL_CONNECTION_MODE'], 'gateway')
        self.assertEqual(env['MODEL_DEPLOYMENT_NAME'], 'reasoning')
        self.assertTrue(env['MODEL_API_KEY_SECRET_URI'].startswith('https://example.vault.azure.net/secrets/'))
        roles = [item['spec'] for item in items if item['kind'] == 'RoleAssignment']
        self.assertEqual([r['roleDefinitionReference']['wellKnownName'] for r in roles], ['Key Vault Secrets User'])
        self.assertIn('/secrets/', roles[0]['owner']['armId'])
        reader = next(item for item in items if item['kind'] == 'RoleAssignment')
        initial = next(item for item in items if item['kind'] == 'Job' and not item['metadata']['name'].endswith('-revoke'))
        self.assertLess(int(initial['metadata']['annotations']['argocd.argoproj.io/sync-wave']),
                        int(reader['metadata']['annotations']['argocd.argoproj.io/sync-wave']))
        self.assertEqual(reader['metadata']['annotations']['argocd.argoproj.io/sync-options'], 'Prune=false,Delete=false')

    def test_repository_and_preview_identity_names_do_not_collide(self):
        inventories = [self.render('repo-one-pr-1'), self.render('repo-one-pr-2'), self.render('repo-two-pr-1', 'org/other')]
        manager_names = []
        owners = []
        for items in inventories:
            config = next(item for item in items if item['kind'] == 'ConfigMap' and 'policy.json' in item.get('data', {}))
            manager_names.append(config['metadata']['name'])
            owners.append(json.loads(config['data']['policy.json'])['identity'])
            revoke = next(item for item in items if item['kind'] == 'Job' and item['metadata']['name'].endswith('-revoke'))
            self.assertEqual(revoke['metadata']['annotations']['argocd.argoproj.io/hook'], 'PostDelete')
            self.assertNotIn('argocd.argoproj.io/sync-options', config['metadata']['annotations'])
            pod = revoke['spec']['template']['spec']
            self.assertEqual(pod['serviceAccountName'], 'litellm-key-writer')
            self.assertEqual(pod['initContainers'][0]['name'], 'revoke-keys')
            self.assertEqual(pod['containers'][0]['command'], ['kubectl'])
            retained = {item['metadata']['name'] for item in items if item['kind'] == 'RoleAssignment'
                        and item['metadata'].get('annotations', {}).get('argocd.argoproj.io/sync-options') == 'Prune=false,Delete=false'}
            permission = next(item for item in items if item['kind'] == 'Role' and item['metadata']['name'].endswith('-revoke'))
            self.assertEqual(set(permission['rules'][0]['resourceNames']), retained)
            deleted = {arg for arg in pod['containers'][0]['args'] if arg in retained}
            self.assertEqual(deleted, retained)
        self.assertEqual(len(set(manager_names)), 3)
        self.assertEqual(len(set(owners)), 3)
