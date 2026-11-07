import copy
import unittest
from unittest.mock import patch
import assistant_coach as coach
import service
import test_meal_agent as fixtures
from test_assistant_coach import payload, reply

def request_v2(health=False, memory=False):
    p = payload(health)
    p.update(contract_version=2, memory_learning=True, text='以后回答简短点')
    p['consent_scope']['memory_summary'] = memory
    return p

def response_v2(p):
    r = reply(p)
    r.update(contract_version=2, cards=[], operations=[{'kind':'remember','source_text':p['text'],'content':p['text'],'topic':'reply_style','evidence_ids':[]}])
    return r

class PersonalAgentChecks(unittest.TestCase):
    def test_v2_with_no_prior_context(self):
        p=request_v2()
        self.assertEqual(coach.respond(p,lambda _:response_v2(p),'skill')['operations'][0]['kind'],'remember')
    def test_model_receives_memory_and_nonwriting_rules(self):
        p=request_v2(memory=True)
        def model(messages):
            self.assertIn('memory_learning=false',messages[0]['content'])
            self.assertIn('只有 App 核对后',messages[0]['content'])
            self.assertEqual(len(messages),2)
            return response_v2(p)
        coach.respond(p,model,'skill')
    def test_model_cannot_claim_an_uncommitted_memory(self):
        p=request_v2();r=response_v2(p);r['operations']=[];r['message']='已记住，以后会注意。'
        with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_pending_operation_cannot_be_called_saved(self):
        p=request_v2();r=response_v2(p);r['message']='我已经帮你记住了。'
        with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_concise_prompt_uses_one_reply_surface(self):
        p=request_v2()
        def model(messages):
            self.assertIn('不要重复展示',messages[0]['content'])
            self.assertIn('默认用一到三句',messages[0]['content'])
            self.assertIn('不解释内部协议',messages[0]['content'])
            return response_v2(p)
        coach.respond(p,model,'skill')
    def test_memory_scope_separate_from_health(self):
        p=request_v2(memory=True)
        fact=payload(True)['snapshot']['facts'][0]
        fact['id']='memory.synthetic';p['snapshot']['facts']=[fact]
        coach.validate_input(p)
        p['consent_scope']['memory_summary']=False
        with self.assertRaises(ValueError):coach.validate_input(p)
    def test_memory_permission_cannot_grant_health(self):
        p=request_v2(memory=True);p['snapshot']['facts']=payload(True)['snapshot']['facts']
        with self.assertRaises(ValueError):coach.validate_input(p)
    def test_disabled_learning_rejects_memory(self):
        p=request_v2();p['memory_learning']=False
        with self.assertRaises(ValueError):coach.validate_reply(response_v2(p),p)
    def test_no_source_no_proposal(self):
        p=request_v2();r=response_v2(p);r['operations'][0]['source_text']='别人说的偏好'
        with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_unknown_target_and_evidence(self):
        p=request_v2()
        for field in ['target_id','evidence_ids']:
            r=response_v2(p);r['operations'][0][field]='invented' if field=='target_id' else ['invented']
            with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_incomplete_or_unknown_operation(self):
        p=request_v2()
        for operation in [{'kind':'logSet'}, {'kind':'updateToday'}, {'kind':'correctSet','target_id':'set.fake'}, {'kind':'remember','content':'ok','topic':'inferred'}, {'kind':'deleteEverything'}]:
            operation.update(source_text=p['text'],evidence_ids=[]);r=response_v2(p);r['operations']=[operation]
            with self.assertRaises(Exception):coach.validate_reply(r,p)
    def test_temporary_memory_has_expiry(self):
        p=request_v2();r=response_v2(p);r['operations'][0]['topic']='temporary'
        with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_pause_has_no_operations(self):
        p=request_v2();r=response_v2(p);r['status']='safety_pause'
        with self.assertRaises(Exception):coach.validate_reply(r,p)
    def test_duplicate_operations_rejected(self):
        p=request_v2();r=response_v2(p);r['operations']*=2
        with self.assertRaises(ValueError):coach.validate_reply(r,p)
    def test_public_context_allowlist(self):
        p=request_v2();fact=payload(True)['snapshot']['facts'][0];fact['id']='public.clock';p['snapshot']['facts']=[fact]
        coach.validate_input(p)
        fact['id']='public.raw-health'
        with self.assertRaises(ValueError):coach.validate_input(p)
    def test_version_one_compatibility(self):
        p=payload();coach.validate_reply(reply(p),p)
        p['contract_version']=3
        with self.assertRaises(Exception):coach.validate_input(p)
    def test_model_has_no_commit_field(self):
        p=request_v2();r=response_v2(p);r['operations'][0]['commit']=True
        with self.assertRaises(Exception):coach.validate_reply(r,p)

class PersonalAgentHTTPChecks(unittest.TestCase):
    setUp=fixtures.ServiceChecks.setUp
    def test_status_advertises_both_contracts(self):
        r=self.client.post('/agent/status',headers=self.headers,json={})
        self.assertEqual(r.json()['assistant_contract_versions'],[1,2])
    def test_v2_request_reaches_selected_model(self):
        p=request_v2()
        with patch.object(service.gateway,'call_model',return_value=response_v2(p)) as call:
            r=self.client.post('/assistant/respond',headers=self.headers,json=p)
        self.assertEqual(r.status_code,200);self.assertEqual(r.json()['contract_version'],2);call.assert_called_once()
    def test_denied_memory_fails_before_provider(self):
        p=request_v2();fact=payload(True)['snapshot']['facts'][0];fact['id']='memory.synthetic';p['snapshot']['facts']=[fact]
        with patch.object(service.gateway,'call_model') as call:
            r=self.client.post('/assistant/respond',headers=self.headers,json=p)
        self.assertEqual(r.status_code,422);call.assert_not_called()
    def test_invalid_operation_never_returned(self):
        p=request_v2();r=response_v2(p);r['operations'][0]['target_id']='memory.invented'
        with patch.object(service.gateway,'call_model',return_value=r):
            response=self.client.post('/assistant/respond',headers=self.headers,json=p)
        self.assertEqual(response.status_code,502);self.assertNotIn('invented',response.text)

if __name__=='__main__':unittest.main()
