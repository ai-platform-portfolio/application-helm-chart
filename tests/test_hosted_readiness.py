"""Render the shared readiness subscription for two independent repositories."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


class HostedReadinessTests(unittest.TestCase):
    def render(self, repository, namespace):
        values = {'name': 'hosted-test', 'gatewayAccess': {'policy': 'bounded'},
                  'platform': {
                      'modelGateway': {'endpoint': 'https://models.example.test/v1',
                                       'vaultUri': 'https://vault.example.test', 'masterSecret': 'gateway-master',
                                       'principalId': '00000000-0000-0000-0000-000000000001',
                                       'consumerIdentity': repository,
                                       'policies': {'bounded': {'maxBudget': 1, 'rpm': 1, 'tpm': 100, 'parallel': 1,
                                                                 'capabilities': {'default': {'model': 'reasoning', 'routes': ['/v1/chat/completions']}}}}},
                      'telemetry': {'namespace': namespace, 'workload': 'api',
                                    'hostname': 'telemetry.example.test',
                                    **{key: '00000000-0000-0000-0000-000000000001'
                                       for key in ['tenantId', 'audience', 'roleId', 'apiPrincipalId']}},
                      'azure': {'tenantId': '00000000-0000-0000-0000-000000000001', 'subscriptionId': '00000000-0000-0000-0000-000000000001',
                                'keyVault': {'name': 'example', 'resourceGroup': 'example'}},
                      'events': {'github': {'appId': '11', 'installationId': '22', 'privateKeyRemoteKey': 'key'}},
                      'hostedReadiness': {'agent': 'triage', 'repository': repository, 'namespace': namespace,
                                          'cluster': 'management', 'workload': 'api'}}}
        with tempfile.TemporaryDirectory() as tmp:
            inputs = Path(tmp) / 'values.json'
            inputs.write_text(json.dumps(values))
            chart = Path(__file__).resolve().parents[1]
            output = subprocess.check_output(['helm', 'template', 'hosted-test', str(chart), '-f', str(inputs)], text=True)
        return [doc for doc in yaml.safe_load_all(output) if doc]

    def test_two_repositories_consume_the_same_subscription_template(self):
        for repo, namespace in [('org/one', 'preview-one'), ('org/two', 'preview-two')]:
            with self.subTest(repo=repo):
                docs = self.render(repo, namespace)
                sensor = next(d for d in docs if d['kind'] == 'Sensor')
                filters = {item['path']: item['value'] for item in sensor['spec']['dependencies'][0]['filters']['data']}
                self.assertEqual(filters['body.alerts.0.labels.namespace'], [f'^{namespace}$'])
                http = sensor['spec']['triggers'][0]['template']['http']
                self.assertEqual(http['url'], f'https://api.github.com/repos/{repo}/dispatches')
                token = next(d for d in docs if d['kind'] == 'GithubAccessToken')
                self.assertEqual(token['spec']['repositories'], [repo.split('/')[1]])
                self.assertEqual(http['secureHeaders'][0]['valueFrom']['secretKeyRef']['name'], token['metadata']['name'])
                self.assertFalse(any(d['kind'] == 'Application' for d in docs))
