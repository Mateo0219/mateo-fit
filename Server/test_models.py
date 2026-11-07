import base64
import json
import os
import unittest
import tempfile
from unittest.mock import patch
import coach_server as gateway
import service
import test_meal_agent as meal_fixtures
from test_assistant_coach import payload,reply

CONFIG={'XUXU_API_URL':'https://api.deepseek.com/chat/completions','XUXU_MODEL':'deepseek-flash','XUXU_PROVIDER_KEY':'synthetic-key'}
class ModelChecks(unittest.TestCase):
    def setUp(self):
        directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
        environment=patch.dict(os.environ,{'XUXU_LIMIT_DB':directory.name+'/counts.db'})
        environment.start();self.addCleanup(environment.stop)
    def test_status_lists_supported_models_and_vision(self):
        with patch.dict(os.environ,CONFIG):
            models=gateway.agent_status()['models']
        self.assertEqual([(x['id'],x['supports_images']) for x in models],[('deepseek-flash',True),('deepseek-v4-pro',False)])
    def test_unknown_model_cannot_expand_provider_access(self):
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'urlopen') as call:
            with self.assertRaises(ValueError):gateway.call_model([],model='arbitrary-external-model')
            call.assert_not_called()
    def test_requested_model_reaches_provider_body(self):
        bodies=[]
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,n):return json.dumps({'choices':[{'message':{'content':'{"ok":true}'}}]}).encode()
        def send(request,timeout):bodies.append(json.loads(request.data));return Response()
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'urlopen',side_effect=send):
            gateway.call_model([{'role':'user','content':'synthetic'}],model='deepseek-v4-pro')
            gateway.call_model([{'role':'user','content':'synthetic'}])
        self.assertEqual([x['model'] for x in bodies],['deepseek-v4-pro','deepseek-flash'])
        self.assertTrue(all(x['thinking']=={'type':'disabled'} for x in bodies))
    def test_text_only_model_rejects_photo(self):
        with patch.dict(os.environ,CONFIG):
            with self.assertRaises(ValueError):gateway.selected_model({'model':'deepseek-v4-pro','image_jpeg_base64':'synthetic'})

class ModelHTTPChecks(unittest.TestCase):
    setUp=meal_fixtures.ServiceChecks.setUp
    def test_selection_is_per_request_and_legacy_default_survives(self):
        with patch.dict(os.environ,CONFIG):
            for model in ['deepseek-v4-pro','deepseek-flash',None]:
                p=payload(False)
                if model:p['model']=model
                with patch.object(gateway,'call_model',return_value=reply(p)) as call:
                    result=self.client.post('/assistant/respond',headers=self.headers,json=p)
                self.assertEqual(result.status_code,200)
                self.assertEqual(call.call_args.kwargs['model'],model or 'deepseek-flash')
    def test_invalid_model_rejected_before_budget_or_provider(self):
        p=payload(False);p['model']='not-allowed'
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'call_model') as call,patch.object(service,'allowed') as budget:
            self.assertEqual(self.client.post('/assistant/respond',headers=self.headers,json=p).status_code,422)
            call.assert_not_called();budget.assert_not_called()
    def test_pro_photo_rejected_before_call(self):
        p=dict(meal_fixtures.PAYLOAD);p['model']='deepseek-v4-pro';p['image_jpeg_base64']=base64.b64encode(b'\xff\xd8\xff'+b'0'*20).decode()
        with patch.dict(os.environ,CONFIG),patch.object(gateway,'call_model') as call:
            self.assertEqual(self.client.post('/meal/analyze',headers=self.headers,json=p).status_code,422)
            call.assert_not_called()
