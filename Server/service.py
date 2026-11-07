"""Single-owner production ASGI service. TLS terminates at the private reverse proxy.
Background jobs temporarily persist encrypted input/results (maximum 24 hours).
Legacy synchronous endpoints do not persist content. Counters contain no content.
"""
import asyncio
import hmac
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from datetime import datetime,timezone
from fastapi import FastAPI,Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.concurrency import run_in_threadpool
import coach_server as gateway
import meal_agent
import assistant_router
import assistant_coach
import deepseek_agent
import provider_budget
import job_routes

for setting in ('XUXU_PROVIDER_KEY','XUXU_CLIENT_TOKEN'):
    filename=os.environ.get(setting+'_FILE')
    if filename: os.environ[setting]=Path(filename).read_text().strip()

app=FastAPI(docs_url=None,redoc_url=None,openapi_url=None)
slots=threading.BoundedSemaphore(2)
limit_lock=threading.Lock()

def reply(code,value):return JSONResponse(value,status_code=code,headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})
def allowed():
    daily = provider_budget.limit('XUXU_MAX_DAILY_REQUESTS')
    minute = provider_budget.limit('XUXU_MAX_MINUTE_REQUESTS')
    try:
        return record_request(daily, minute)
    except Exception:
        if daily < 0 and minute < 0:
            return True
        raise

def record_request(daily_limit, minute_limit):
    """Account for requests; enforce only explicitly configured quotas."""
    now=int(time.time()); minute=str(now//60); day=datetime.now(timezone.utc).strftime('%Y-%m-%d')
    dbpath=Path(os.environ.get('XUXU_LIMIT_DB','/data/limits.sqlite3'))
    dbpath.parent.mkdir(parents=True,exist_ok=True)
    with limit_lock,sqlite3.connect(dbpath,timeout=3) as db:
        db.execute('CREATE TABLE IF NOT EXISTS counters (bucket TEXT PRIMARY KEY, count INTEGER NOT NULL)')
        db.execute('BEGIN IMMEDIATE')
        keys=('minute:'+minute,'day:'+day)
        counts=[(db.execute('SELECT count FROM counters WHERE bucket=?',(key,)).fetchone() or [0])[0] for key in keys]
        if (minute_limit >= 0 and counts[0] >= minute_limit) or (daily_limit >= 0 and counts[1] >= daily_limit): return False
        for key in keys:db.execute('INSERT INTO counters VALUES (?,1) ON CONFLICT(bucket) DO UPDATE SET count=count+1',(key,))
        db.execute('DELETE FROM counters WHERE bucket NOT IN (?,?)',keys)
    return True

def provider_allowed():
    return provider_budget.allowed()

def provider_error(error):
    if isinstance(error,(provider_budget.BudgetError,deepseek_agent.AgentFailure)):
        if str(error)=='budget_exhausted':return reply(429,{'error':'budget_exhausted'})
        if str(error)=='limiter_unavailable':return reply(503,{'error':'limiter_unavailable'})
    return reply(502,{'error':'provider_unavailable_or_invalid_response'})

async def generate(payload, emit, meal=False):
    kwargs={'meal':True} if meal else {}
    await asyncio.wait_for(deepseek_agent.run(payload,emit,provider_allowed,**kwargs),timeout=300)

def perform(path,payload):
    try:
        model = gateway.selected_model(payload)
        invoke = lambda messages: gateway.call_model(messages, model=model)
        if path=='/assistant/respond':return assistant_coach.respond(payload,invoke,gateway.prompt('assistant').split('Required response schema')[0])
        if path=='/assistant/route':return assistant_router.route(payload,gateway.call_model)
        if path=='/meal/analyze':return meal_agent.analyze(payload,invoke,gateway.prompt('meal').split('Required response schema')[0])
        return gateway.propose(payload)
    finally:slots.release()

@app.get('/health')
async def health(): return reply(200,{'status':'ok'})

@app.post('/assistant/stream')
@app.post('/meal/stream')
async def stream_assistant(request: Request):
    token=os.environ.get('XUXU_CLIENT_TOKEN','')
    if len(token)<32 or not hmac.compare_digest(request.headers.get('Authorization',''),'Bearer '+token):return reply(401,{'error':'unauthorized'})
    meal=request.url.path=='/meal/stream'
    try:
        async def collect():
            raw=bytearray()
            async for chunk in request.stream():
                raw.extend(chunk)
                if len(raw)>(2_100_000 if meal else 65_536):raise OverflowError()
            return raw
        payload=json.loads(await asyncio.wait_for(collect(),12));meal_agent.finite(payload)
        (meal_agent.validate_input if meal else assistant_coach.validate_input)(payload);deepseek_agent.options(payload);gateway.selected_model(payload)
        if not meal and payload.get('contract_version')!=2:raise ValueError()
    except OverflowError:return reply(413,{'error':'request_too_large'})
    except Exception:return reply(422,{'error':'request_rejected'})
    if not gateway.configured() or not deepseek_agent.capabilities()['streaming']:return reply(503,{'error':'capability_unavailable'})
    try:
        if not allowed():return reply(429,{'error':'rate_limited'})
    except Exception:return reply(503,{'error':'limiter_unavailable'})
    if not slots.acquire(blocking=False):return reply(429,{'error':'busy'})
    async def events():
        queue=asyncio.Queue(maxsize=128);sequence=0
        async def emit(kind,**fields):
            nonlocal sequence
            sequence+=1
            await queue.put(dict(request_id=payload['request_id'],sequence=sequence,type=kind,**fields))
        async def worker():
            try:await generate(payload,emit,meal=meal)
            except asyncio.CancelledError:raise
            except asyncio.TimeoutError:await emit('error',code='timeout')
            except Exception as error:
                code=str(error) if isinstance(error,deepseek_agent.AgentFailure) else 'invalid_response'
                await emit('error',code=code if code in ('budget_exhausted','limiter_unavailable','incomplete_response','uncommitted_write_claim','web_provider_unavailable') else 'provider_unavailable')
        task=asyncio.create_task(worker())
        try:
            while not task.done() or not queue.empty():
                try:event=await asyncio.wait_for(queue.get(),10)
                except asyncio.TimeoutError:
                    yield b': keepalive\n\n';continue
                yield ('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode()
                if event['type'] in ('result','error'):break
        finally:
            task.cancel()
            try:
                await asyncio.gather(task,return_exceptions=True)
            finally:
                # ASGI disconnect can cancel this cleanup await as well.
                slots.release()
    return StreamingResponse(events(),media_type='text/event-stream',headers={'Cache-Control':'no-store','X-Accel-Buffering':'no','X-Content-Type-Options':'nosniff'})

@app.post('/agent/status')
@app.post('/meal/analyze')
@app.post('/coach')
@app.post('/assistant/route')
@app.post('/assistant/respond')
async def handle(request: Request):
    token=os.environ.get('XUXU_CLIENT_TOKEN','')
    if len(token)<32 or not hmac.compare_digest(request.headers.get('Authorization',''),'Bearer '+token):return reply(401,{'error':'unauthorized'})
    if request.url.path=='/agent/status':return reply(200,dict(gateway.agent_status(),storage="encrypted_jobs_24h",usage_limits=provider_budget.policy(),assistant_features=dict(deepseek_agent.capabilities(),**job_capabilities())))
    size_limit=2_100_000 if request.url.path=='/meal/analyze' else 65_536 if request.url.path=='/assistant/respond' else 32_768
    try:
        if int(request.headers.get('content-length','0'))>size_limit:return reply(413,{'error':'request_too_large'})
        async def collect():
            chunks=bytearray()
            async for chunk in request.stream():
                if len(chunks)+len(chunk)>size_limit: raise OverflowError('too_large')
                chunks.extend(chunk)
            return chunks
        payload=json.loads(await asyncio.wait_for(collect(),timeout=12))
        meal_agent.finite(payload)
        (meal_agent.validate_input if request.url.path=='/meal/analyze' else assistant_router.validate_input if request.url.path=='/assistant/route' else assistant_coach.validate_input if request.url.path=='/assistant/respond' else gateway.validate_input)(payload)
        gateway.selected_model(payload)
    except OverflowError:return reply(413,{'error':'request_too_large'})
    except Exception:return reply(422,{'error':'request_rejected'})
    if not gateway.configured():return reply(503,{'error':'provider_not_configured'})
    try:
        if not allowed():return reply(429,{'error':'rate_limited'})
    except Exception:return reply(503,{'error':'limiter_unavailable'})
    if not slots.acquire(blocking=False):return reply(429,{'error':'busy'})
    if request.url.path in ('/assistant/respond','/meal/analyze') and 'generation' in payload:
        result={}
        async def collect_result(kind,**fields):
            if kind=='result':result.update(fields['response'])
        try:
            await generate(payload,collect_result,meal=request.url.path=='/meal/analyze')
            return reply(200,result)
        except Exception as error:return provider_error(error)
        finally:slots.release()
    try:
        result=await run_in_threadpool(perform,request.url.path,payload)
        return reply(200,result)
    except Exception as error:return provider_error(error)

job_capabilities = job_routes.install(app, generate, slots, allowed, reply)
