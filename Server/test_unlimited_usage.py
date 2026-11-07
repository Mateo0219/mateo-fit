"""Explicit user policy: no application daily or per-minute usage quotas."""
import json
import os
import sqlite3
import time
import unittest
import uuid
from datetime import datetime, timezone
from unittest.mock import patch
from pathlib import Path
import httpx
from fastapi.testclient import TestClient
import provider_budget
import service
import coach_server as gateway
import deepseek_agent as agent
import test_meal_agent as meals
from test_models import CONFIG
from test_personal_agent import request_v2, response_v2
from test_deepseek_agent import completion
import test_provider_budget as budget_checks
from test_provider_budget import Response

NAMES = ('XUXU_MAX_DAILY_PROVIDER_CALLS','XUXU_MAX_DAILY_REQUESTS','XUXU_MAX_MINUTE_REQUESTS')

class UnlimitedChecks(unittest.TestCase):
    def setUp(self):
        meals.ServiceChecks.setUp(self)
        for name in NAMES: os.environ.pop(name, None)

    def seed(self, count=1000000):
        day=datetime.now(timezone.utc).strftime('%Y-%m-%d');minute=str(int(time.time())//60)
        with sqlite3.connect(os.environ['XUXU_LIMIT_DB']) as db:
            db.execute('CREATE TABLE provider_counters(day TEXT PRIMARY KEY,count INTEGER NOT NULL)')
            db.execute('INSERT INTO provider_counters VALUES (?,?)',(day,count))
            db.execute('CREATE TABLE counters(bucket TEXT PRIMARY KEY,count INTEGER NOT NULL)')
            db.executemany('INSERT INTO counters VALUES (?,?)',[('day:'+day,count),('minute:'+minute,count)])

    def test_default_unlimited_above_old_daily_and_minute_limits(self):
        self.seed()
        self.assertTrue(provider_budget.allowed());self.assertTrue(service.allowed())
        with sqlite3.connect(os.environ['XUXU_LIMIT_DB']) as db:
            self.assertEqual(db.execute('SELECT count FROM provider_counters').fetchone()[0],1000001)
            self.assertEqual(db.execute("SELECT count FROM counters WHERE bucket LIKE 'day:%'").fetchone()[0],1000001)

    def test_explicit_minus_one_is_unlimited(self):
        self.seed()
        with patch.dict(os.environ,{name:'-1' for name in NAMES}):
            for _ in range(15):
                self.assertTrue(provider_budget.allowed());self.assertTrue(service.allowed())

    def test_status_reports_no_app_quotas_without_model_call(self):
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'urlopen') as network:
            result=self.client.post('/agent/status',headers=self.headers,json={})
            self.assertEqual(result.status_code,200)
            self.assertEqual(result.json()['usage_limits'],{'provider_calls_per_day':None,'requests_per_day':None,'requests_per_minute':None})
            network.assert_not_called()

    def test_all_legacy_http_paths_work_after_old_quota_was_exhausted(self):
        self.seed()
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'prompt',return_value='synthetic skill'):
            for path,body,result in budget_checks.BudgetHTTPChecks.legacy_cases(self):
                with self.subTest(path=path),patch.object(gateway,'urlopen',return_value=Response(result)) as network:
                    response=self.client.post(path,headers=self.headers,json=body)
                    self.assertEqual(response.status_code,200,response.text);network.assert_called_once()

    def test_background_job_completes_after_old_quota_exhausted(self):
        self.seed()
        p=request_v2();p.update(request_id=str(uuid.uuid4()).upper(),model='deepseek-flash',generation={'effort':'none','web_mode':'off'})
        calls=[];original=httpx.AsyncClient
        def upstream(request):calls.append(request);return completion(json.dumps(response_v2(p)))
        def factory(*args,**kwargs):return original(transport=httpx.MockTransport(upstream))
        body={'device_id':str(uuid.uuid4()),'thread_id':str(uuid.uuid4()),'kind':'assistant','request':p}
        with patch.dict(os.environ,CONFIG),patch.object(agent.httpx,'AsyncClient',side_effect=factory),TestClient(service.app) as client:
            accepted=client.post('/agent/jobs',headers=self.headers,json=body);self.assertEqual(accepted.status_code,200,accepted.text)
            path='/agent/jobs/'+p['request_id']
            for _ in range(100):
                status=client.get(path,headers=self.headers).json()
                if status['state']=='completed':break
                time.sleep(.02)
            self.assertEqual(status['state'],'completed',status);self.assertEqual(len(calls),1)
            self.assertEqual(client.post(path+'/ack',headers=self.headers).json()['state'],'acknowledged')

    def test_disabled_quota_not_blocked_by_optional_accounting_failure(self):
        with patch.dict(os.environ,{'XUXU_LIMIT_DB':self.directory.name}):
            self.assertTrue(provider_budget.allowed());self.assertTrue(service.allowed())

    def test_opt_in_quota_still_fails_closed_if_accounting_unavailable(self):
        with patch.dict(os.environ,{'XUXU_LIMIT_DB':self.directory.name,'XUXU_MAX_DAILY_PROVIDER_CALLS':'1','XUXU_MAX_DAILY_REQUESTS':'1'}):
            with self.assertRaises(sqlite3.OperationalError):provider_budget.allowed()
            with self.assertRaises(sqlite3.OperationalError):service.allowed()

    def test_install_templates_do_not_reenable_limits(self):
        root=Path(__file__).parent
        unit=(root/'mateo-fit-agent.service').read_text();compose=(root/'compose.yaml').read_text()
        for name in NAMES:
            self.assertIn('Environment='+name+'=-1',unit)
            self.assertIn(name+': "-1"',compose)

if __name__=='__main__':unittest.main()
