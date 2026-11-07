import asyncio
import base64
import copy
import json
import os
import unittest
from unittest.mock import patch
import httpx
import deepseek_agent as agent
import service
from test_models import CONFIG
from test_personal_agent import request_v2, response_v2
import test_meal_agent as meal_fixtures

class Events(httpx.AsyncByteStream):
    def __init__(self,chunks):self.chunks=chunks;self.closed=False
    async def __aiter__(self):
        for chunk in self.chunks:yield chunk
    async def aclose(self):self.closed=True

def completion(content='',calls=None,reasoning='synthetic-private-reasoning',done=True,finish='stop'):
    deltas=[{'reasoning_content':reasoning}]
    for piece in (content[:len(content)//2],content[len(content)//2:]):deltas.append({'content':piece})
    if calls:
        for i,c in enumerate(calls):deltas.append({'tool_calls':[dict(index=i,**c)]})
    rows=[{'choices':[{'index':0,'delta':d,'finish_reason':None}]} for d in deltas]
    rows.append({'choices':[{'index':0,'delta':{},'finish_reason':'tool_calls' if calls else finish}], 'usage':{'prompt_tokens':100,'completion_tokens':30,'prompt_cache_hit_tokens':40,'completion_tokens_details':{'reasoning_tokens':12}}})
    chunks=[('data: '+json.dumps(row,ensure_ascii=False)+'\n\n').encode() for row in rows]
    if done:chunks.append(b'data: [DONE]\n\n')
    return httpx.Response(200,stream=Events(chunks))

def tool(name,args,i='call1'):
    return {'id':i,'type':'function','function':{'name':name,'arguments':json.dumps(args)}}

def final(p,**kw):
    r=response_v2(p);r['message']='请核对这条记忆。';r.update(kw)
    return json.dumps(r,ensure_ascii=False)

class ProviderChecks(unittest.IsolatedAsyncioTestCase):
    async def test_all_efforts_reach_real_provider_body_and_stream_omits_reasoning(self):
        for effort in agent.EFFORTS:
            bodies=[];events=[];p=request_v2();p['generation']={'effort':effort,'web_mode':'off'}
            async def http(request):bodies.append(json.loads(request.content));return completion(final(p))
            async def emit(kind,**fields):events.append(dict(type=kind,**fields))
            async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
                with patch.dict(os.environ,CONFIG):await agent.run(p,emit,lambda:True,client=client)
            self.assertTrue(bodies[0]['stream']);self.assertEqual(bodies[0]['thinking']['type'],'disabled' if effort=='none' else 'enabled')
            self.assertEqual(bodies[0].get('reasoning_effort'),None if effort=='none' else effort)
            self.assertNotIn('synthetic-private-reasoning',json.dumps(events))
            result=events[-1]['response'];self.assertEqual(result['generation']['cache_hit_tokens'],40)
            self.assertEqual(result['generation']['reasoning_tokens'],12)
            self.assertTrue(result['generation']['reasoning_present'])
            self.assertTrue(any(e['type']=='message' for e in events))
    async def test_research_preserves_tool_reasoning_and_uses_only_registered_sources(self):
        p=request_v2();p['text']='合成测试：查询公开运动指南';p['generation']={'effort':'high','web_mode':'research'}
        events=[];models=[];web=[];paid=[]
        async def http(request):
            body=json.loads(request.content)
            if request.url.path.endswith('/search'):
                web.append(body);return httpx.Response(200,json={'results':[{'url':'https://www.who.int/example','title':'Public guideline','summary':'Synthetic public summary'}]})
            if request.url.path.endswith('/fetch'):
                web.append(body);return httpx.Response(200,json={'title':'Public guideline','content':'Synthetic original page content'})
            models.append(body)
            if len(models)==1:return completion(calls=[tool('search_web',{'query':'public physical activity guideline'})])
            if len(models)==2:
                self.assertEqual(body['messages'][2]['reasoning_content'],'synthetic-private-reasoning')
                return completion(calls=[tool('fetch_page',{'url':'https://www.who.int/example'},'read1')])
            if len(models)==3:return completion('Enough sources')
            return completion(final(p,message='公开指南支持活动。[S1]',operations=[],citation_ids=['S1']))
        async def emit(kind,**fields):events.append(dict(type=kind,**fields))
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG):await agent.run(p,emit,lambda:paid.append(True) or True,client=client)
        result=events[-1]['response']
        self.assertEqual(len(paid),6);self.assertEqual(len(web),2)
        self.assertEqual(result['sources'][0]['url'],'https://www.who.int/example');self.assertTrue(result['sources'][0]['read'])
        self.assertEqual(result['generation']['search_calls'],1);self.assertEqual(result['generation']['fetch_calls'],1)
        self.assertNotIn('snapshot',models[0]['messages'][1]['content'])
    async def test_incomplete_stream_never_emits_result(self):
        p=request_v2();events=[]
        async def http(request):return completion(final(p),done=False,finish='length')
        async def emit(kind,**fields):events.append(kind)
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG),self.assertRaises(agent.AgentFailure):await agent.run(p,emit,lambda:True,client=client)
        self.assertNotIn('result',events)
    async def test_forged_citation_rejected(self):
        p=request_v2()
        async def http(request):return completion(final(p,citation_ids=['S9']))
        async def emit(*args,**kw):pass
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG),self.assertRaises(agent.AgentFailure):await agent.run(p,emit,lambda:True,client=client)
    async def test_research_does_not_accept_model_invented_inline_urls(self):
        p=request_v2();p['generation']={'effort':'low','web_mode':'search'}
        async def http(request):return completion(final(p,message='查看 https://invented.example/secret',citation_ids=[]))
        async def emit(*args,**kwargs):pass
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG),patch.object(agent,'research',return_value=[]),self.assertRaisesRegex(agent.AgentFailure,'unregistered_inline_url'):
                await agent.run(p,emit,lambda:True,client=client)

    async def test_client_disconnect_cancels_worker_and_releases_service_slot(self):
        first=asyncio.Event();stopped=asyncio.Event();sent=[];received=False
        async def run(payload,emit,charge,**kwargs):
            try:
                await emit('status',stage='thinking')
                await asyncio.Event().wait()
            finally:stopped.set()
        async def receive():
            nonlocal received
            if not received:
                received=True
                return {'type':'http.request','body':json.dumps(request_v2()).encode(),'more_body':False}
            await first.wait()
            return {'type':'http.disconnect'}
        async def send(message):
            sent.append(message)
            if message['type']=='http.response.body' and message.get('body'):first.set()
        token='synthetic-token-000000000000000000000000'
        scope={'type':'http','asgi':{'version':'3.0','spec_version':'2.0'},'method':'POST','path':'/assistant/stream','raw_path':b'/assistant/stream','query_string':b'','headers':[(b'authorization',('Bearer '+token).encode()),(b'content-type',b'application/json')],'scheme':'https','server':('testserver',443),'client':('127.0.0.1',1000),'http_version':'1.1','root_path':''}
        with patch.dict(os.environ,dict(CONFIG,XUXU_CLIENT_TOKEN=token)),patch.object(service,'allowed',return_value=True),patch.object(agent,'run',side_effect=run):
            await asyncio.wait_for(service.app(scope,receive,send),3)
        self.assertTrue(stopped.is_set())
        self.assertFalse(any(b'"type": "result"' in m.get('body',b'') for m in sent))
        acquired=[service.slots.acquire(blocking=False) for _ in range(2)]
        for held in acquired:
            if held:service.slots.release()
        self.assertEqual(acquired,[True,True])

    async def test_photo_thinking_uses_actual_vision_request_and_deterministic_meal_result(self):
        p=dict(meal_fixtures.PAYLOAD,generation={'effort':'low','web_mode':'off'},image_jpeg_base64=base64.b64encode(b'\xff\xd8\xff'+b'0'*20).decode())
        bodies=[];events=[]
        async def http(request):bodies.append(json.loads(request.content));return completion(json.dumps(meal_fixtures.RAW))
        async def emit(kind,**fields):events.append(dict(type=kind,**fields))
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG):await agent.run(p,emit,lambda:True,client=client,meal=True)
        self.assertEqual(bodies[0]['reasoning_effort'],'low')
        self.assertEqual(bodies[0]['messages'][1]['content'][1]['type'],'image_url')
        self.assertTrue(events[-1]['response']['requires_confirmation'])
        self.assertEqual(events[-1]['response']['source'],'AI 估计')
        self.assertIsNotNone(events[-1]['response']['totals']['energyKcal'])
    async def test_unknown_provider_usage_is_not_filled_with_zero(self):
        p=request_v2();events=[]
        async def http(request):
            chunks=[('data: '+json.dumps({'choices':[{'delta':{'content':final(p)},'finish_reason':'stop'}]})+'\n\n').encode(),b'data: [DONE]\n\n']
            return httpx.Response(200,stream=Events(chunks))
        async def emit(kind,**fields):events.append(dict(type=kind,**fields))
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG):await agent.run(p,emit,lambda:True,client=client)
        self.assertIsNone(events[-1]['response']['generation']['reasoning_tokens'])
        self.assertIsNone(events[-1]['response']['generation']['cache_hit_tokens'])
    async def test_budget_rejection_precedes_paid_call(self):
        calls=[]
        async def http(request):calls.append(request);return completion('{}')
        async def emit(*args,**kw):pass
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG),self.assertRaisesRegex(agent.AgentFailure,'budget_exhausted'):await agent.run(request_v2(),emit,lambda:False,client=client)
        self.assertEqual(calls,[])
    async def test_cancel_closes_inflight_stream_and_emits_no_result(self):
        started=asyncio.Event();closed=asyncio.Event();events=[]
        class Slow(httpx.AsyncByteStream):
            async def __aiter__(self):
                started.set();await asyncio.sleep(30);yield b'data: [DONE]\n\n'
            async def aclose(self):closed.set()
        async def http(request):return httpx.Response(200,stream=Slow())
        async def emit(kind,**fields):events.append(kind)
        async with httpx.AsyncClient(transport=httpx.MockTransport(http)) as client:
            with patch.dict(os.environ,CONFIG):
                task=asyncio.create_task(agent.run(request_v2(),emit,lambda:True,client=client))
                await asyncio.wait_for(started.wait(),2);task.cancel()
                with self.assertRaises(asyncio.CancelledError):await task
        self.assertTrue(closed.is_set());self.assertNotIn('result',events)

class SafetyChecks(unittest.TestCase):
    def test_public_urls_and_query_boundaries(self):
        for url in ['http://www.who.int','https://127.0.0.1/x','https://localhost/x','https://user:pass@example.com','https://10.0.0.1','https://[::1]','https://private.local']:
            self.assertFalse(agent.public_url(url),url)
        self.assertTrue(agent.public_url('https://www.who.int/news'))
        for q in ['','x'*129,'person@example.com','13800138000','token=secret']:self.assertFalse(agent.query_allowed(q))
    def test_partial_reply_does_not_stream_json_or_success_claim(self):
        self.assertEqual(agent.visible_message('{"message":"你好。后半'),'你好。')
        self.assertEqual(agent.visible_message('{"message":"未完成的句子'),'')
        with self.assertRaises(agent.AgentFailure):agent.visible_message('{"message":"已记住。"')
    def test_unknown_generation_fields_rejected(self):
        for opt in [{'effort':'ultra','web_mode':'off'},{'effort':'none','web_mode':'all'},{'effort':'none','web_mode':'off','tools':'write'}]:
            with self.assertRaises(agent.AgentFailure):agent.options({'generation':opt})

class StreamHTTPChecks(unittest.TestCase):
    setUp=meal_fixtures.ServiceChecks.setUp
    def test_auth_and_invalid_input_before_provider(self):
        with patch.object(agent,'run') as run:
            self.assertEqual(self.client.post('/assistant/stream',json=request_v2()).status_code,401)
            p=request_v2();p['consent_scope']['text']=False
            self.assertEqual(self.client.post('/assistant/stream',headers=self.headers,json=p).status_code,422)
            run.assert_not_called()
    def test_ordered_events_and_terminal_result(self):
        p=request_v2()
        async def run(payload,emit,charge):
            await emit('status',stage='thinking');await emit('message',text='请核对。');await emit('result',response=response_v2(payload))
        with patch.dict(os.environ,CONFIG),patch.object(agent,'run',side_effect=run):
            r=self.client.post('/assistant/stream',headers=self.headers,json=p)
        self.assertEqual(r.status_code,200)
        events=[json.loads(x[6:]) for x in r.text.splitlines() if x.startswith('data: ')]
        self.assertEqual([e['sequence'] for e in events],[1,2,3]);self.assertTrue(all(e['request_id']==p['request_id'] for e in events))
        self.assertEqual(events[-1]['type'],'result');self.assertEqual(r.headers['x-accel-buffering'],'no')
    def test_provider_error_is_terminal_without_result(self):
        async def run(*args):raise agent.AgentFailure('budget_exhausted')
        with patch.dict(os.environ,CONFIG),patch.object(agent,'run',side_effect=run):
            r=self.client.post('/assistant/stream',headers=self.headers,json=request_v2())
        self.assertIn('budget_exhausted',r.text);self.assertNotIn('"type": "result"',r.text)
    def test_status_exposes_actual_capabilities(self):
        with patch.dict(os.environ,CONFIG):
            r=self.client.post('/agent/status',headers=self.headers,json={})
        self.assertEqual(r.json()['assistant_features']['thinking_efforts'],['none','low','high','max'])
    def test_provider_budget_persists_and_is_separate_from_user_rate_count(self):
        with patch.dict(os.environ,{'XUXU_MAX_DAILY_PROVIDER_CALLS':'2'}):
            self.assertTrue(service.provider_allowed());self.assertTrue(service.allowed())
            self.assertTrue(service.provider_allowed());self.assertFalse(service.provider_allowed())

if __name__=='__main__':unittest.main()
