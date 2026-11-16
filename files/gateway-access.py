"""Trusted finite-key lifecycle using native LiteLLM, Redis and Key Vault APIs.

Never run this with an application identity. Policy and endpoint configuration
come from reviewed platform values; no request or document data is accepted.
"""
import hashlib
import json
import math
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone


ROUTES = {'/v1/responses', '/v1/chat/completions', '/v1/embeddings'}


def validate(config):
    policy = config['policy']
    for name in ('maxBudget', 'rpm', 'tpm', 'parallel'):
        value = policy.get(name)
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError('Positive explicit budget and rate ceilings are required')
    if policy.get('budgetDuration') not in {'1d', '7d', '30d'}:
        raise ValueError('Declare the stable owner budget reset period')
    if not policy.get('capabilities'):
        raise ValueError('Declare capability-scoped models')
    for name, capability in policy['capabilities'].items():
        if name not in {'default', 'coding', 'embedding'}:
            raise ValueError('Unknown capability')
        if (not capability.get('model') or '*' in capability['model']
                or not capability.get('routes') or not set(capability['routes']) <= ROUTES):
            raise ValueError('Declare exact model and inference-only routes')
        for field in ('rpm', 'tpm', 'parallel'):
            capability.setdefault(field, policy[field])
            if type(capability.get(field)) is not int or not 0 < capability[field] <= policy[field]:
                raise ValueError('Capability ceilings must fit owner policy')


class Manager:
    def __init__(self, config, api, vault, now=None):
        validate(config)
        self.config, self.api, self.vault = config, api, vault
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.owner = 'consumer-' + hashlib.sha256(config['identity'].encode()).hexdigest()
        self.control_name = config['name'] + '-control'
        self.policy_hash = hashlib.sha256(json.dumps(config['policy'], sort_keys=True).encode()).hexdigest()

    def load(self):
        try:
            record = json.loads(self.vault.get_secret(self.control_name).value)
        except Exception as error:
            if getattr(error, 'status_code', None) != 404:
                raise
            record = {'owner': self.owner, 'created': False, 'keys': []}
        if record['owner'] != self.owner:
            raise ValueError('Credential control owner differs')
        return record

    def save(self, record):
        self.vault.set_secret(self.control_name, json.dumps(record, separators=(',', ':')),
                              tags={'owner': self.owner, 'purpose': 'issuer-control'})

    def user(self, record):
        policy = self.config['policy']
        result = self.api('GET', '/user/info', params={'user_id': self.owner}, missing=True)
        info = result.get('user_info') if result else None
        models = sorted({c['model'] for c in policy['capabilities'].values()})
        fields = {'user_id': self.owner, 'models': models, 'max_budget': policy['maxBudget'],
                  'rpm_limit': policy['rpm'], 'tpm_limit': policy['tpm'],
                  'max_parallel_requests': policy['parallel']}
        if info is None:
            if record['created']:
                raise ValueError('Previously provisioned accounting owner is missing; restore required')
            self.api('POST', '/user/new', json={**fields, 'auto_create_key': False,
                     'user_role': 'internal_user', 'budget_duration': policy['budgetDuration'],
                     'metadata': {'gateway_owner': self.owner}})
        else:
            if (info.get('metadata', {}).get('gateway_owner') != self.owner
                    or info.get('budget_duration') != policy['budgetDuration']):
                raise ValueError('Existing owner or budget reset period differs')
            # Never send spend or reset timestamps: rotation is not a new allowance.
            self.api('POST', '/user/update', json=fields)
        checked = self.api('GET', '/user/info', params={'user_id': self.owner})['user_info']
        if (checked.get('metadata', {}).get('gateway_owner') != self.owner
                or checked.get('max_budget') != policy['maxBudget']
                or sorted(checked.get('models', [])) != models):
            raise ValueError('Owner policy readback differs')
        record['created'] = True
        self.save(record)

    def info(self, key):
        result = self.api('POST', '/v2/key/info', json={'keys': [key]})['info']
        if len(result) > 1:
            raise ValueError('Ambiguous key ownership')
        return result[0] if result else None

    def check(self, item, info):
        capability = self.config['policy']['capabilities'][item['capability']]
        if (info.get('user_id') != self.owner or info.get('team_id') is not None
                or info.get('models') != [capability['model']]
                or sorted(info.get('allowed_routes', [])) != sorted(capability['routes'])
                or info.get('key_alias') != item['alias']
                or info.get('rpm_limit') != capability['rpm']
                or info.get('tpm_limit') != capability['tpm']
                or info.get('max_parallel_requests') != capability['parallel']):
            raise ValueError('Key model, route or ownership readback differs')
        expires = datetime.fromisoformat(str(info['expires']).replace('Z', '+00:00'))
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        if expires > datetime.fromisoformat(item['expires']) + timedelta(seconds=5) or expires <= self.now():
            raise ValueError('Key expiry readback differs')

    def revoke(self, item):
        info = self.info(item['key'])
        if info is not None:
            if info.get('user_id') != self.owner or info.get('key_alias') != item['alias']:
                raise ValueError('Refusing to revoke another owner key')
            self.api('POST', '/key/delete', json={'keys': [item['key']]})

    def reconcile(self, delete=False):
        record = self.load()
        if delete:
            for item in record['keys']:
                self.revoke(item)
            for capability in self.config['policy']['capabilities']:
                # Retain issuer control and stable accounting owner across removal.
                # A later retry/reapply must not grant a fresh spend allowance.
                self.vault.set_secret(self.config['name'] + '-' + capability, 'revoked',
                                      enabled=False, expires_on=self.now(), tags={'owner': self.owner})
            record['keys'] = []
            self.save(record)
            return
        self.user(record)
        for capability, policy in self.config['policy']['capabilities'].items():
            current = next((k for k in reversed(record['keys']) if k['capability'] == capability
                            and k.get('policy') == self.policy_hash and k.get('published')
                            and datetime.fromisoformat(k['expires']) > self.now() + timedelta(hours=24)), None)
            if current is not None:
                self.check(current, self.info(current['key']) or {})
                continue
            item = next((k for k in record['keys'] if k['capability'] == capability
                         and k.get('policy') == self.policy_hash and not k.get('published')
                         and datetime.fromisoformat(k['expires']) > self.now() + timedelta(minutes=5)), None)
            if item is None:
                item = {'capability': capability, 'key': 'sk-' + secrets.token_hex(32),
                        'alias': self.owner + '-' + capability + '-' + secrets.token_hex(8),
                        'expires': (self.now() + timedelta(hours=48)).isoformat(), 'published': False,
                        'policy': self.policy_hash}
                record['keys'].append(item)
                self.save(record)
            info = self.info(item['key'])
            if info is None:
                remaining = int((datetime.fromisoformat(item['expires']) - self.now()).total_seconds())
                self.api('POST', '/key/generate', json={
                    'key': item['key'], 'key_alias': item['alias'], 'user_id': self.owner,
                    'duration': f'{remaining}s', 'models': [policy['model']],
                    'allowed_routes': policy['routes'], 'rpm_limit': policy['rpm'],
                    'tpm_limit': policy['tpm'], 'max_parallel_requests': policy['parallel'],
                    'metadata': {'gateway_owner': self.owner, 'capability': capability}})
                info = self.info(item['key'])
            self.check(item, info or {})
            self.vault.set_secret(self.config['name'] + '-' + capability, item['key'],
                                  enabled=True, expires_on=datetime.fromisoformat(item['expires']),
                                  tags={'owner': self.owner, 'capability': capability})
            item['published'] = True
            self.save(record)
        retained = []
        for item in record['keys']:
            if (datetime.fromisoformat(item['expires']) <= self.now()
                    or item.get('policy') != self.policy_hash):
                self.revoke(item)
                if item['capability'] not in self.config['policy']['capabilities']:
                    self.vault.set_secret(self.config['name'] + '-' + item['capability'], 'revoked',
                                          enabled=False, expires_on=self.now(), tags={'owner': self.owner})
            else:
                retained.append(item)
        record['keys'] = retained
        self.save(record)


def main():
    import httpx
    import redis
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient
    config = json.loads(os.environ['GATEWAY_POLICY_JSON'])
    credential = DefaultAzureCredential()
    vault = SecretClient(vault_url=config['vault'], credential=credential,
                         connection_timeout=5, read_timeout=10, retry_total=0)
    master = vault.get_secret(config['masterSecret']).value
    client = httpx.Client(base_url='http://litellm.litellm.svc.cluster.local:4000',
                          headers={'Authorization': 'Bearer ' + master}, timeout=20, trust_env=False)
    def api(method, path, missing=False, **kwargs):
        response = client.request(method, path, **kwargs)
        if missing and response.status_code == 404:
            return None
        if response.status_code >= 400:
            raise RuntimeError('Gateway management request failed')
        return response.json()
    cache = redis.Redis(host='redis.redis.svc.cluster.local', port=6379, ssl=True,
                        ssl_ca_certs='/redis/ca.crt', ssl_certfile='/redis/tls.crt',
                        ssl_keyfile='/redis/tls.key', ssl_check_hostname=True,
                        socket_connect_timeout=5, socket_timeout=10)
    # No competing process may outlive the lock: Job active deadline is shorter.
    lock = cache.lock('litellm:gateway-access:' + config['name'], timeout=600, blocking_timeout=5)
    with credential, vault, client, cache, lock:
        deleting = sys.argv[1:] == ['delete']
        Manager(config, api, vault).reconcile(delete=deleting)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # API exceptions may contain key material. Never print messages/tracebacks.
        print('Gateway credential operation failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
