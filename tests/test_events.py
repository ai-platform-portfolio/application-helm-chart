"""Real Helm renders check generic subscriptions, isolation and least privilege."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def values():
    return {'namespace': 'consumer-one', 'events': {
        'sources': {'changes': {'resource': {'updated': {
            'namespace': 'target', 'group': '', 'version': 'v1', 'resource': 'configmaps', 'eventTypes': ['UPDATE']}}}},
        'sensors': {'notify': {'dependencies': [{'name': 'changed', 'eventSourceName': 'changes', 'eventName': 'updated'}],
            'triggers': [{'template': {'name': 'notify', 'http': {'url': 'https://example.test/changed',
                'method': 'POST', 'secureHeaders': [{'name': 'Authorization', 'valueFrom': {
                    'secretKeyRef': {'name': 'dispatch', 'key': 'authorization'}}}]}}}]}},
        'githubTokens': {'dispatch': {'repository': 'example/consumer', 'permissions': {'contents': 'write'}}}},
        'platform': {'events': {'github': {'appId': '123', 'installationId': '456', 'privateKeyRemoteKey': 'existing-key'}}}}


class EventTests(unittest.TestCase):
    def render(self, intent, release='consumer'):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'values.json'
            path.write_text(json.dumps(intent))
            return subprocess.run(['helm', 'template', release, str(ROOT), '-f', str(path)],
                                  text=True, capture_output=True)

    def documents(self, intent, release='consumer'):
        result = self.render(intent, release)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    def test_empty_maps_create_no_event_resources(self):
        self.assertEqual(self.documents({'namespace': 'consumer'}), [])

    def test_one_account_local_references_and_key_boundary(self):
        intent = values()
        intent['events']['sources']['second'] = deepcopy(intent['events']['sources']['changes'])
        docs = self.documents(intent)
        accounts = [d for d in docs if d['kind'] == 'ServiceAccount']
        self.assertEqual(len(accounts), 1)
        account = accounts[0]['metadata']['name']
        for document in docs:
            if document['kind'] in {'EventSource', 'Sensor'}:
                self.assertEqual(document['spec']['template']['serviceAccountName'], account)
        source = next(d for d in docs if d['kind'] == 'EventSource' and 'changes' in d['metadata']['name'])
        sensor = next(d for d in docs if d['kind'] == 'Sensor')
        self.assertEqual(sensor['spec']['dependencies'][0]['eventSourceName'], source['metadata']['name'])
        token = next(d for d in docs if d['kind'] == 'GithubAccessToken')
        secret = sensor['spec']['triggers'][0]['template']['http']['secureHeaders'][0]['valueFrom']['secretKeyRef']
        self.assertEqual(secret['name'], token['metadata']['name'])
        secret_roles = [d for d in docs if d['kind'] == 'Role' and d['rules'][0]['resources'] == ['secrets']]
        self.assertEqual(len(secret_roles), 1)
        self.assertEqual(secret_roles[0]['rules'], [{'apiGroups': [''], 'resources': ['secrets'],
            'resourceNames': [token['metadata']['name']], 'verbs': ['get']}])
        watches = [d for d in docs if d['kind'] == 'Role' and d['metadata']['namespace'] == 'target']
        self.assertTrue(watches)
        self.assertTrue(all(d['rules'] == [{'apiGroups': [''], 'resources': ['configmaps'],
                                         'verbs': ['get', 'list', 'watch']}] for d in watches))

    def test_reuse_existing_account_without_creating_another(self):
        intent = values()
        intent['platform']['events']['serviceAccountName'] = 'existing-consumer'
        docs = self.documents(intent)
        self.assertFalse(any(d['kind'] == 'ServiceAccount' for d in docs))
        for document in docs:
            if document['kind'] in {'EventSource', 'Sensor'}:
                self.assertEqual(document['spec']['template']['serviceAccountName'], 'existing-consumer')

    def test_different_namespaces_and_releases_have_disjoint_generated_names(self):
        first = self.documents(values())
        other = values()
        other['namespace'] = 'consumer-two'
        def names(docs):
            return {d['metadata']['name'] for d in docs if d['kind'] != 'Namespace'}
        self.assertFalse(names(first) & names(self.documents(other)))
        self.assertFalse(names(first) & names(self.documents(values(), 'second')))
        self.assertEqual(names(first), names(self.documents(values())))

    def test_no_anonymous_webhook_or_cluster_wide_watch(self):
        for sources in ({'hook': {'webhook': {'changed': {'port': '12000', 'endpoint': '/changed'}}}},
                        {'changes': {'resource': {'updated': {'namespace': '', 'resource': 'configmaps'}}}},
                        {'changes': {'resource': {'updated': {'namespace': 'target', 'resource': 'configmaps', 'watchCluster': True}}}}):
            intent = values()
            intent['events']['sources'] = sources
            self.assertNotEqual(self.render(intent).returncode, 0)

    def test_registration_preserves_event_inputs_and_disables_child_registration(self):
        intent = values()
        intent['platform']['credentials'] = {'roles': {'external-reader': {
            'metadata': {'namespace': 'target'},
            'rules': [{'apiGroups': [''], 'resources': ['pods'], 'verbs': ['get']}]}}}
        intent['name'] = 'consumer'
        intent['platform']['argocd'] = {'enabled': True, 'repository': 'https://github.com/example/consumer',
                                       'revision': 'a' * 40, 'chartRevision': 'b' * 40}
        app = next(d for d in self.documents(intent) if d['kind'] == 'Application')
        forwarded = app['spec']['sources'][0]['helm']['valuesObject']
        self.assertEqual(forwarded['events'], intent['events'])
        self.assertFalse(forwarded['platform']['argocd']['enabled'])
        self.assertEqual(forwarded['platform']['credentials']['roles'], intent['platform']['credentials']['roles'])


if __name__ == '__main__':
    unittest.main()
