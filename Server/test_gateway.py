import copy
import json
import os
import threading
import unittest
from http.server import HTTPServer
from urllib.request import Request, build_opener, ProxyHandler
urlopen = build_opener(ProxyHandler({})).open
from urllib.error import HTTPError
import coach_server as server

REQUEST={'mode':'meal','consent':True,'snapshot_id':'test-only','question':'Give a meal candidate','evidence':[{'id':'pantry','value':['rice']}],'expected_plan_version':None}
REPLY={'mode':'meal','status':'proposal','snapshot_id':'test-only','expected_plan_version':None,'message':'Candidate','questions':[],'limitations':[],'recommendations':[{'title':'a','action':'b','reason':'c','evidence_ids':['pantry'],'uncertainty':'portion unknown','requires_confirmation':True}]}
class Checks(unittest.TestCase):
    def test_valid(self):
        server.validate_input(REQUEST)
        self.assertEqual(server.validate_reply(REPLY,REQUEST),REPLY)
    def test_consent(self):
        item=copy.deepcopy(REQUEST);item['consent']=False
        with self.assertRaises(ValueError):server.validate_input(item)
    def test_duplicate_evidence(self):
        item=copy.deepcopy(REQUEST);item['evidence']*=2
        with self.assertRaises(ValueError):server.validate_input(item)
    def test_invented_evidence(self):
        item=copy.deepcopy(REPLY);item['recommendations'][0]['evidence_ids']=['fiction']
        with self.assertRaises(ValueError):server.validate_reply(item,REQUEST)
    def test_stale(self):
        item=copy.deepcopy(REPLY);item['snapshot_id']='old'
        with self.assertRaises(ValueError):server.validate_reply(item,REQUEST)
    def test_wrong_plan(self):
        item=copy.deepcopy(REPLY);item['expected_plan_version']='different'
        with self.assertRaises(ValueError):server.validate_reply(item,REQUEST)
    def test_no_automatic_write(self):
        item=copy.deepcopy(REPLY);item['recommendations'][0]['requires_confirmation']=False
        with self.assertRaises(Exception):server.validate_reply(item,REQUEST)
    def test_pause_has_no_training(self):
        item=copy.deepcopy(REPLY);item['status']='safety_pause'
        with self.assertRaises(Exception):server.validate_reply(item,REQUEST)
    def test_modes_load_real_skill(self):
        for mode in server.MODES:self.assertIn('Required response schema',server.prompt(mode))
    def test_http_auth_and_not_configured(self):
        old=dict(os.environ)
        os.environ['XUXU_CLIENT_TOKEN']='test-only-token-00000000000000000000'
        os.environ.pop('XUXU_PROVIDER_KEY',None)
        http=HTTPServer(('127.0.0.1',0),server.Handler)
        thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
        base='http://127.0.0.1:'+str(http.server_port)
        try:
            self.assertEqual(json.load(urlopen(base+'/health'))['status'],'not_configured')
            for token,code in [('',401),(os.environ['XUXU_CLIENT_TOKEN'],503)]:
                request=Request(base+'/coach',data=json.dumps(REQUEST).encode(),headers={'Authorization':'Bearer '+token})
                with self.assertRaises(HTTPError) as error:urlopen(request)
                self.assertEqual(error.exception.code,code)
        finally:
            http.shutdown();http.server_close();os.environ.clear();os.environ.update(old)
if __name__=='__main__':unittest.main()
