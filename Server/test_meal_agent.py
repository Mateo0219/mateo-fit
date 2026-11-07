import base64,copy,json,os,tempfile,unittest
from unittest.mock import patch
import meal_agent as meal
from fastapi.testclient import TestClient
import service

PAYLOAD={'request_id':'test-request','description':'synthetic rice, no real user data','consent':True}
RAW={'request_id':'test-request','title':'合成米饭','summary':'合成测试','questions':[],'limitations':[],'all_components_included':True,'items':[{'name':'米饭','catalog_id':'rice','grams_low':100,'grams_high':200,'note':'合成份量'}],'label':None}
class MealChecks(unittest.TestCase):
    def test_catalog_sources(self):
        foods=meal.catalog();self.assertEqual(len(foods),31)
        for food in foods.values():
            self.assertTrue(food['source_url'].startswith('https://fdc.nal.usda.gov/'))
            self.assertEqual(set(food['per100g']),set(meal.NUTRIENTS))
    def test_calculated_range(self):
        r=meal.calculate(RAW,PAYLOAD);rate=meal.catalog()['rice']['per100g']['energyKcal']
        self.assertEqual(r['totals']['energyKcal'],{'low':rate,'high':rate*2})
        self.assertTrue(r['requires_confirmation'])
    def test_unknown_does_not_become_zero(self):
        raw=copy.deepcopy(RAW);raw['items'][0]['catalog_id']=None
        self.assertTrue(all(v is None for v in meal.calculate(raw,PAYLOAD)['totals'].values()))
    def test_incomplete_dish_no_false_total(self):
        raw=copy.deepcopy(RAW);raw['all_components_included']=False
        self.assertIsNone(meal.calculate(raw,PAYLOAD)['totals']['energyKcal'])
    def test_missing_portion(self):
        raw=copy.deepcopy(RAW);raw['items'][0]['grams_low']=None
        self.assertIsNone(meal.calculate(raw,PAYLOAD)['totals']['energyKcal'])
    def test_reject_invented_food(self):
        raw=copy.deepcopy(RAW);raw['items'][0]['catalog_id']='invented'
        with self.assertRaises(ValueError):meal.calculate(raw,PAYLOAD)
    def test_reject_reversed_range(self):
        raw=copy.deepcopy(RAW);raw['items'][0]['grams_low']=300
        with self.assertRaises(ValueError):meal.calculate(raw,PAYLOAD)
    def test_reject_nan(self):
        raw=copy.deepcopy(RAW);raw['items'][0]['grams_low']=float('nan')
        with self.assertRaises(ValueError):meal.calculate(raw,PAYLOAD)
    def test_reject_stale(self):
        raw=copy.deepcopy(RAW);raw['request_id']='old'
        with self.assertRaises(ValueError):meal.calculate(raw,PAYLOAD)
    def test_label_conversion_and_missing_protein(self):
        payload=dict(PAYLOAD,image_jpeg_base64='not-needed-for-calculation-unit-test')
        raw=copy.deepcopy(RAW);raw['items']=[];raw['label']={'basis_grams':100,'energy_unit':'kJ','energy':418.4,'protein':None,'carbs':20,'fat':2,'grams_low':150,'grams_high':150,'note':'synthetic'}
        result=meal.calculate(raw,payload)
        self.assertEqual(result['totals']['energyKcal'],{'low':150,'high':150});self.assertIsNone(result['totals']['proteinG']);self.assertEqual(result['catalog_version'],'label-extraction-v1')
        with self.assertRaises(ValueError):meal.calculate(raw,PAYLOAD)
    def test_input_consent_and_no_health_scope(self):
        for change in [{'consent':False},{'health_records':[]},{'description':''},{'image_jpeg_base64':'bad'}]:
            with self.assertRaises(Exception):meal.validate_input(dict(PAYLOAD,**change))
    def test_instructions_do_not_become_tools(self):
        def model(messages):
            self.assertNotIn('tools',messages[0]);self.assertIn('untrusted',messages[0]['content']);return RAW
        self.assertEqual(meal.analyze(PAYLOAD,model,'test skill')['request_id'],'test-request')

class ServiceChecks(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.addCleanup(self.directory.cleanup)
        self.environment=patch.dict(os.environ,{'XUXU_CLIENT_TOKEN':'synthetic-token-000000000000000000000000','XUXU_LIMIT_DB':self.directory.name+'/counts.db','XUXU_PROVIDER_KEY':'synthetic-key','XUXU_MODEL':'test','XUXU_API_URL':'https://example.invalid/chat','XUXU_MAX_DAILY_REQUESTS':'100'})
        self.environment.start();self.addCleanup(self.environment.stop)
        self.client=TestClient(service.app);self.headers={'Authorization':'Bearer '+os.environ['XUXU_CLIENT_TOKEN']}
    def test_auth_before_provider(self):
        with patch.object(service.gateway,'call_model') as call:
            self.assertEqual(self.client.post('/meal/analyze',json=PAYLOAD).status_code,401);call.assert_not_called()
    def test_status_checks_configuration_only(self):
        with patch.object(service.gateway,'call_model') as call:
            r=self.client.post('/agent/status',headers=self.headers,json={});self.assertEqual(r.json()['status'],'ready');call.assert_not_called()
    def test_limits_and_sensitive_payload_rejection(self):
        self.assertEqual(self.client.post('/meal/analyze',headers=self.headers,json=dict(PAYLOAD,consent=False)).status_code,422)
        self.assertEqual(self.client.post('/meal/analyze',headers=self.headers,content=b'x'*2_100_001).status_code,413)
    def test_success_no_auto_commit(self):
        with patch.object(service.gateway,'call_model',return_value=RAW):
            r=self.client.post('/meal/analyze',headers=self.headers,json=PAYLOAD)
        self.assertEqual(r.status_code,200);self.assertTrue(r.json()['requires_confirmation'])
        import sqlite3
        with sqlite3.connect(os.environ['XUXU_LIMIT_DB']) as db:
            self.assertEqual({r[1] for r in db.execute('PRAGMA table_info(counters)')},{'bucket','count'})
    def test_provider_errors_redacted(self):
        with patch.object(service.gateway,'call_model',side_effect=RuntimeError('DO-NOT-LEAK synthetic-key')):
            r=self.client.post('/meal/analyze',headers=self.headers,json=PAYLOAD)
        self.assertEqual(r.status_code,502);self.assertNotIn('DO-NOT-LEAK',r.text)
    def test_missing_model(self):
        with patch.dict(os.environ,{'XUXU_PROVIDER_KEY':''}):
            self.assertEqual(self.client.post('/meal/analyze',headers=self.headers,json=PAYLOAD).status_code,503)
    def test_daily_limit_persists(self):
        with patch.dict(os.environ,{'XUXU_MAX_DAILY_REQUESTS':'1'}):
            self.assertTrue(service.allowed());self.assertFalse(service.allowed())
    def test_minute_limit(self):
        with patch.dict(os.environ, {'XUXU_MAX_MINUTE_REQUESTS': '10'}):
            self.assertTrue(all(service.allowed() for _ in range(10)));self.assertFalse(service.allowed())
if __name__=='__main__':unittest.main()
