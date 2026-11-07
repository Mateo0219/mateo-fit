"""Production HTTP boundary regressions; all upstream traffic is synthetic."""
import base64
import copy
import json
import os
import sqlite3
import unittest
from unittest.mock import patch
import httpx
import coach_server as gateway
import deepseek_agent as agent
import provider_budget
import service
import test_meal_agent as meals
from test_assistant_coach import payload, reply
from test_deepseek_agent import completion, tool
from test_gateway import REQUEST, REPLY
from test_models import CONFIG
from test_personal_agent import request_v2, response_v2

class Response:
    def __init__(self, result): self.result = result
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, size):
        return json.dumps({'choices': [{'message': {'content': json.dumps(self.result)}}]}).encode()

class BudgetHTTPChecks(unittest.TestCase):
    setUp = meals.ServiceChecks.setUp

    def counts(self):
        with sqlite3.connect(os.environ['XUXU_LIMIT_DB']) as db:
            names = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            paid = db.execute('SELECT COALESCE(SUM(count),0) FROM provider_counters').fetchone()[0] if 'provider_counters' in names else 0
            user = db.execute("SELECT COALESCE(SUM(count),0) FROM counters WHERE bucket LIKE 'day:%'").fetchone()[0] if 'counters' in names else 0
            return paid, user

    def assert_slots_released(self):
        acquired = [service.slots.acquire(blocking=False) for _ in range(2)]
        for held in acquired:
            if held: service.slots.release()
        self.assertEqual(acquired, [True, True])

    def legacy_cases(self):
        v1 = payload(False); v2 = request_v2()
        photo = dict(meals.PAYLOAD, image_jpeg_base64=base64.b64encode(b'\xff\xd8\xff' + b'0' * 20).decode())
        route = {'request_id': 'route-test', 'text': '合成测试：打开设置', 'history': [], 'consent': True}
        return [('/meal/analyze', dict(meals.PAYLOAD), meals.RAW),
                ('/meal/analyze', photo, meals.RAW),  # existing photo edit/form flow has no generation
                ('/assistant/respond', v1, reply(v1)),
                ('/assistant/respond', v2, response_v2(v2)),
                ('/assistant/route', route, dict(request_id='route-test', status='ready', reply='查看设置。', actions=['settings'])),
                ('/coach', copy.deepcopy(REQUEST), REPLY)]

    def test_every_legacy_http_path_counts_one_actual_network_attempt(self):
        with patch.dict(os.environ, CONFIG), patch.object(gateway, 'prompt', return_value='synthetic skill'):
            for i, (path, body, result) in enumerate(self.legacy_cases(), 1):
                with self.subTest(path=path, number=i), patch.object(gateway, 'urlopen', return_value=Response(result)) as network:
                    response = self.client.post(path, headers=self.headers, json=body)
                    self.assertEqual(response.status_code, 200, response.text)
                    network.assert_called_once()
                    self.assertEqual(self.counts(), (i, i))
                    self.assert_slots_released()

    def test_exhausted_paid_budget_blocks_all_legacy_paths_with_user_quota_left(self):
        with patch.dict(os.environ, dict(CONFIG, XUXU_MAX_DAILY_PROVIDER_CALLS='1')):
            self.assertTrue(service.provider_allowed())
            for path, body, _ in self.legacy_cases():
                with self.subTest(path=path), patch.object(gateway, 'urlopen') as network:
                    response = self.client.post(path, headers=self.headers, json=body)
                    self.assertEqual(response.status_code, 429, response.text)
                    self.assertEqual(response.json()['error'], 'budget_exhausted')
                    network.assert_not_called()
                    self.assert_slots_released()
            self.assertEqual(self.counts(), (1, 6))
            self.assertTrue(service.allowed())  # provider denial was not the user-request limit

    def test_new_json_and_stream_paths_charge_once_and_stop_at_exhaustion(self):
        original_client = httpx.AsyncClient
        cases = [('/assistant/respond', False), ('/meal/analyze', True), ('/assistant/stream', False), ('/meal/stream', True)]
        for i, (path, meal) in enumerate(cases, 1):
            body = copy.deepcopy(meals.PAYLOAD if meal else request_v2())
            body['generation'] = {'effort': 'low', 'web_mode': 'off'}
            result = meals.RAW if meal else response_v2(body)
            calls = []
            def upstream(request):
                calls.append(request)
                return completion(json.dumps(result))
            def client_factory(*args, **kwargs):
                return original_client(transport=httpx.MockTransport(upstream))
            with self.subTest(path=path), patch.dict(os.environ, dict(CONFIG, XUXU_MAX_DAILY_PROVIDER_CALLS=str(i))), patch.object(agent.httpx, 'AsyncClient', side_effect=client_factory):
                accepted = self.client.post(path, headers=self.headers, json=body)
                self.assertEqual(accepted.status_code, 200, accepted.text)
                self.assertEqual(len(calls), 1)
                self.assertEqual(self.counts(), (i, i * 2 - 1))
                denied = self.client.post(path, headers=self.headers, json=body)
                if path.endswith('stream'):
                    self.assertIn('"code": "budget_exhausted"', denied.text)
                    self.assertNotIn('"type": "result"', denied.text)
                else:
                    self.assertEqual(denied.status_code, 429, denied.text)
                    self.assertEqual(denied.json()['error'], 'budget_exhausted')
                self.assertEqual(len(calls), 1)
                self.assertEqual(self.counts(), (i, i * 2))
                self.assert_slots_released()

    def test_research_counts_model_search_and_fetch_exactly_once_then_blocks_legacy(self):
        p = request_v2(); p['text'] = '查询公开运动指南'
        p['generation'] = {'effort': 'high', 'web_mode': 'research'}
        calls = []; models = []
        def upstream(request):
            calls.append(request.url.path)
            if request.url.path.endswith('/search'):
                return httpx.Response(200, json={'results': [{'url': 'https://www.who.int/example', 'title': 'Synthetic source', 'summary': 'Synthetic summary'}]})
            if request.url.path.endswith('/fetch'):
                return httpx.Response(200, json={'content': 'Synthetic page'})
            models.append(json.loads(request.content))
            if len(models) == 1: return completion(calls=[tool('search_web', {'query': 'public activity guideline'})])
            if len(models) == 2: return completion(calls=[tool('fetch_page', {'url': 'https://www.who.int/example'}, 'read1')])
            if len(models) == 3: return completion('Enough sources')
            result = response_v2(p); result.update(message='合成公开资料。[S1]', operations=[], citation_ids=['S1'])
            return completion(json.dumps(result))
        original_client = httpx.AsyncClient
        def client_factory(*args, **kwargs): return original_client(transport=httpx.MockTransport(upstream))
        with patch.dict(os.environ, dict(CONFIG, XUXU_MAX_DAILY_PROVIDER_CALLS='6')), patch.object(agent.httpx, 'AsyncClient', side_effect=client_factory), patch.object(gateway, 'urlopen') as legacy:
            result = self.client.post('/assistant/respond', headers=self.headers, json=p)
            self.assertEqual(result.status_code, 200, result.text)
            self.assertEqual(len(calls), 6); self.assertEqual(self.counts(), (6, 1))
            self.assertEqual(result.json()['generation']['model_calls'], 4)
            self.assertEqual(result.json()['generation']['search_calls'], 1)
            self.assertEqual(result.json()['generation']['fetch_calls'], 1)
            denied = self.client.post('/meal/analyze', headers=self.headers, json=meals.PAYLOAD)
            self.assertEqual(denied.status_code, 429); legacy.assert_not_called()
            self.assert_slots_released()

    def test_status_and_invalid_requests_never_consume_paid_budget(self):
        with patch.dict(os.environ, dict(CONFIG, XUXU_MAX_DAILY_PROVIDER_CALLS='0')), patch.object(gateway, 'urlopen') as network:
            for _ in range(3):
                self.assertEqual(self.client.post('/agent/status', headers=self.headers, json={}).status_code, 200)
                self.assertEqual(self.client.get('/health').status_code, 200)
            self.assertEqual(self.client.post('/meal/analyze', json=meals.PAYLOAD).status_code, 401)
            self.assertEqual(self.client.post('/meal/analyze', headers=self.headers, json=dict(meals.PAYLOAD, consent=False)).status_code, 422)
            network.assert_not_called(); self.assertEqual(self.counts(), (0, 0))

    def test_failed_attempt_counts_once_and_releases_slot(self):
        with patch.dict(os.environ, CONFIG), patch.object(gateway, 'urlopen', side_effect=OSError('synthetic upstream failed')) as network:
            failed = self.client.post('/meal/analyze', headers=self.headers, json=meals.PAYLOAD)
            self.assertEqual(failed.status_code, 502); network.assert_called_once()
            self.assertEqual(self.counts(), (1, 1)); self.assert_slots_released()
        original_client = httpx.AsyncClient
        calls = []
        def upstream(request): calls.append(request); return httpx.Response(500)
        def client_factory(*args, **kwargs): return original_client(transport=httpx.MockTransport(upstream))
        with patch.dict(os.environ, CONFIG), patch.object(agent.httpx, 'AsyncClient', side_effect=client_factory):
            p = request_v2(); p['generation'] = {'effort': 'none', 'web_mode': 'off'}
            failed = self.client.post('/assistant/respond', headers=self.headers, json=p)
            self.assertEqual(failed.status_code, 502); self.assertEqual(len(calls), 1)
            self.assertEqual(self.counts(), (2, 2)); self.assert_slots_released()

    def test_budget_store_failure_is_closed_and_does_not_leak_slot(self):
        with patch.dict(os.environ, CONFIG), patch.object(provider_budget, 'allowed', side_effect=OSError('synthetic db path')), patch.object(gateway, 'urlopen') as network:
            failed = self.client.post('/meal/analyze', headers=self.headers, json=meals.PAYLOAD)
            self.assertEqual(failed.status_code, 503); self.assertEqual(failed.json()['error'], 'limiter_unavailable')
            network.assert_not_called(); self.assert_slots_released()

if __name__ == '__main__': unittest.main()
