import asyncio
import copy
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid
from fastapi import FastAPI
from fastapi.testclient import TestClient
from background_jobs import JobStore, JobRunner, JobError
import job_routes
from service import reply
from test_personal_agent import request_v2, response_v2

class StoreChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.now = 1000
        self.path = Path(self.tmp.name) / 'jobs.db'
        self.store = JobStore(self.path, self.path.with_suffix('.key'), clock=lambda:self.now, retention=100)
        self.charges = 0
    def charge(self): self.charges += 1; return True
    def submit(self, key='job', payload=None):
        return self.store.submit(key,'owner','device','thread','assistant',payload or {'text':'synthetic-sensitive-marker'},self.charge)
    def test_duplicate_submission_charged_once_and_conflict_rejected(self):
        self.assertTrue(self.submit()); self.assertFalse(self.submit()); self.assertEqual(self.charges,1)
        with self.assertRaisesRegex(JobError,'conflict'): self.submit(payload={'text':'different'})
        self.assertEqual(self.charges,1)
    def test_inputs_preview_results_encrypted_and_ack_erases(self):
        self.submit(); self.store.claim('job'); self.store.progress('job',preview='synthetic-private-preview')
        self.store.finish('job',result={'message':'synthetic-private-result'})
        raw=self.path.read_bytes()
        for value in [b'synthetic-sensitive-marker',b'synthetic-private-preview',b'synthetic-private-result']: self.assertNotIn(value,raw)
        self.assertEqual(self.store.status('job','owner')['response']['message'],'synthetic-private-result')
        self.assertEqual(self.store.acknowledge('job','owner')['state'],'acknowledged')
        self.assertNotIn('response',self.store.status('job','owner')); self.assertFalse(self.submit())
        with self.store.connect() as db: self.assertEqual(tuple(db.execute('SELECT payload,result,preview FROM jobs').fetchone()),(None,None,None))
        self.assertEqual(self.path.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.path.with_suffix('.key').stat().st_mode & 0o777,0o600)
    def test_stop_before_post_tombstone_prevents_late_submission(self):
        self.store.cancel('job','owner'); self.assertFalse(self.submit()); self.assertEqual(self.charges,0)
        self.assertEqual(self.store.status('job','owner')['state'],'cancelled')
    def test_stop_rejects_late_reply(self):
        self.submit(); self.store.claim('job'); self.store.cancel('job','owner')
        self.assertFalse(self.store.finish('job',{'message':'late'})); self.assertNotIn('response',self.store.status('job','owner'))
    def test_queue_bound_and_owner_isolation(self):
        for i in range(4): self.submit(str(i))
        with self.assertRaisesRegex(JobError,'queue_full'): self.submit('5')
        with self.assertRaisesRegex(JobError,'not_found'): self.store.status('0','other-owner')
        self.assertEqual(self.charges,4)
    def test_ttl_wipes_content_and_keeps_idempotency_tombstone(self):
        self.submit(); self.now += 101
        self.assertEqual(self.store.status('job','owner')['state'],'expired'); self.assertFalse(self.submit()); self.assertEqual(self.charges,1)
        self.now+=101
        with self.assertRaisesRegex(JobError,'not_found'): self.store.status('job','owner')
    def test_restart_does_not_replay_running_but_keeps_queued(self):
        self.submit('running'); self.submit('queued'); self.store.claim('running')
        self.store.recover('owner')
        self.assertEqual(self.store.status('running','owner')['error'],'server_restarted'); self.assertEqual(self.store.queued(),['queued'])
    def test_key_rotation_revokes_old_owner(self):
        self.submit(); self.store.recover('new-owner'); self.assertEqual(self.store.queued(),[])
    def test_ack_cannot_discard_work_in_progress(self):
        self.submit(); self.assertEqual(self.store.acknowledge('job','owner')['state'],'queued')

class RunnerChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        path=Path(self.tmp.name)/'jobs.db'; self.store=JobStore(path,path.with_suffix('.key'))
        self.slots=threading.BoundedSemaphore(1); self.calls=0; self.release=asyncio.Event(); self.started=asyncio.Event()
        async def generate(p, emit, meal=False):
            self.calls+=1; self.started.set(); await self.release.wait()
            await emit('message',text='synthetic preview'); await emit('result',response={'message':'done'})
        self.runner=JobRunner(self.store,'owner',generate,self.slots); await self.runner.start()
        self.addAsyncCleanup(self.runner.close)
    def submit(self,key): self.store.submit(key,'owner','device','thread','assistant',{},lambda:True)
    async def wait_state(self,key,state):
        for _ in range(80):
            if self.store.status(key,'owner')['state']==state:return
            await asyncio.sleep(.02)
        self.fail('state did not reach '+state)
    async def test_generation_runs_without_a_polling_connection(self):
        self.submit('job'); await asyncio.wait_for(self.started.wait(),2)
        self.release.set(); await self.wait_state('job','completed'); self.assertEqual(self.calls,1)
    async def test_cancel_releases_concurrency_slot(self):
        self.submit('a'); self.submit('b'); await asyncio.wait_for(self.started.wait(),2)
        self.runner.cancel('a','owner'); self.release.set(); await self.wait_state('b','completed')
        self.assertEqual(self.store.status('a','owner')['state'],'cancelled'); self.assertEqual(self.calls,2)
    async def test_shutdown_marks_running_interrupted_no_paid_replay(self):
        self.submit('a'); await asyncio.wait_for(self.started.wait(),2); await self.runner.close()
        self.assertEqual(self.store.status('a','owner')['state'],'failed'); self.assertTrue(self.slots.acquire(False)); self.slots.release()
    async def test_queued_timeout_does_not_invoke_provider(self):
        self.store.clock=lambda:time.time()-700; self.submit('a'); self.store.clock=time.time
        await self.wait_state('a','failed'); self.assertEqual(self.calls,0)

class RoutesChecks(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.patch=patch.dict(os.environ,{'XUXU_CLIENT_TOKEN':'synthetic-token-'+('0'*32),'XUXU_JOB_DB':self.tmp.name+'/jobs.db','XUXU_MODEL':'deepseek-flash','XUXU_API_URL':'https://api.deepseek.com/chat/completions'})
        self.patch.start();self.addCleanup(self.patch.stop)
        self.calls=0;self.charges=0;self.app=FastAPI()
        async def generate(p,emit,meal=False):
            self.calls+=1;await asyncio.sleep(.12);await emit('result',response=response_v2(p))
        def charge():self.charges+=1;return True
        self.capabilities=job_routes.install(self.app,generate,threading.BoundedSemaphore(2),charge,reply)
        self.config=patch('job_routes.gateway.configured',return_value=True);self.config.start();self.addCleanup(self.config.stop)
        self.p=request_v2();self.p['request_id']=str(uuid.uuid4()).upper();self.p['model']='deepseek-flash'
        self.body={'device_id':str(uuid.uuid4()),'thread_id':str(uuid.uuid4()),'kind':'assistant','request':self.p}
        self.headers={'Authorization':'Bearer '+os.environ['XUXU_CLIENT_TOKEN']}
    def test_authenticated_submit_disconnect_poll_ack_and_duplicate(self):
        with TestClient(self.app) as client:
            self.assertTrue(self.capabilities()['background_jobs']);self.assertFalse(self.capabilities()['completion_notifications'])
            self.assertEqual(client.post('/agent/jobs',json=self.body).status_code,401)
            path='/agent/jobs/'+self.p['request_id']
            response=client.post('/agent/jobs',json=self.body,headers=self.headers);self.assertEqual(response.status_code,200);response.close()
            time.sleep(.45) # No open request while the server generates.
            result=client.get(path,headers=self.headers).json();self.assertEqual(result['state'],'completed')
            self.assertEqual(client.post('/agent/jobs',json=self.body,headers=self.headers).json()['state'],'completed')
            self.assertEqual((self.calls,self.charges),(1,1))
            self.assertEqual(client.post(path+'/ack',headers=self.headers).json()['state'],'acknowledged')
            self.assertNotIn('response',client.get(path,headers=self.headers).json())
        self.assertFalse(self.capabilities()['background_jobs'])
    def test_invalid_or_unauthorized_summary_never_creates_job(self):
        with TestClient(self.app) as client:
            bad=copy.deepcopy(self.body);bad['request']['consent_scope']['text']=False
            self.assertEqual(client.post('/agent/jobs',json=bad,headers=self.headers).status_code,422)
            bad=copy.deepcopy(self.body);bad['request']['request_id']='not-uuid'
            self.assertEqual(client.post('/agent/jobs',json=bad,headers=self.headers).status_code,422)
            self.assertEqual(self.charges,0)
    def test_delete_before_submit_and_late_result_are_terminal(self):
        with TestClient(self.app) as client:
            path='/agent/jobs/'+self.p['request_id']
            self.assertEqual(client.delete(path,headers=self.headers).json()['state'],'cancelled')
            self.assertEqual(client.post('/agent/jobs',json=self.body,headers=self.headers).json()['state'],'cancelled')
            self.assertEqual((self.calls,self.charges),(0,0))

if __name__=='__main__':unittest.main()
