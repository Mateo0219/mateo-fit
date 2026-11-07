"""Authenticated job transport; submission is idempotent, polling is read-only."""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import uuid
from fastapi import Request
import assistant_coach
import meal_agent
import deepseek_agent
import coach_server as gateway
from background_jobs import JobStore, JobRunner, JobError


def owner():
    return hashlib.sha256(os.environ.get('XUXU_CLIENT_TOKEN', '').encode()).hexdigest()


def identifier(value):
    return isinstance(value, str) and len(value) == 36 and str(uuid.UUID(value)).lower() == value.lower()


def install(app, generate, slots, charge_request, reply):
    runner = None

    async def startup():
        nonlocal runner
        path = Path(os.environ.get('XUXU_JOB_DB', str(Path(os.environ.get('XUXU_LIMIT_DB', '/data/limits.sqlite3')).with_name('jobs.sqlite3'))))
        try:
            store = JobStore(path, os.environ.get('XUXU_JOB_KEY_FILE', str(path.with_suffix('.key'))))
            runner = JobRunner(store, owner(), generate, slots)
            await runner.start()
        except Exception:
            runner = None

    async def shutdown():
        nonlocal runner
        if runner:
            await runner.close()
        runner = None

    previous_lifespan = app.router.lifespan_context
    @asynccontextmanager
    async def lifespan(application):
        async with previous_lifespan(application):
            await startup()
            try:
                yield
            finally:
                await shutdown()
    app.router.lifespan_context = lifespan

    def capabilities():
        ready = runner is not None and runner.pump is not None and not runner.pump.done()
        return {'background_jobs': ready, 'job_retention_hours': 24, 'completion_notifications': False}

    async def body(request, limit):
        async def collect():
            data = bytearray()
            async for chunk in request.stream():
                data.extend(chunk)
                if len(data) > limit:
                    raise OverflowError()
            return data
        value = json.loads(await asyncio.wait_for(collect(), 15))
        meal_agent.finite(value)
        return value

    def authorized(request):
        token = os.environ.get('XUXU_CLIENT_TOKEN', '')
        return len(token) >= 32 and hmac.compare_digest(request.headers.get('Authorization', ''), 'Bearer ' + token)

    @app.post('/agent/jobs')
    @app.get('/agent/jobs/{job_id}')
    @app.delete('/agent/jobs/{job_id}')
    @app.post('/agent/jobs/{job_id}/ack')
    async def handle(request: Request, job_id: str = None):
        if not authorized(request):
            return reply(401, {'error': 'unauthorized'})
        if runner is None or (job_id is None and not capabilities()['background_jobs']):
            return reply(503, {'error': 'background_unavailable'})
        try:
            current = owner()
            if job_id is not None:
                if not identifier(job_id):
                    raise JobError('request_rejected')
                if request.method == 'DELETE':
                    runner.cancel(job_id, current)
                elif request.method == 'POST':
                    runner.store.acknowledge(job_id, current)
                return reply(200, runner.store.status(job_id, current))
            value = await body(request, 2_110_000)
            if set(value) != {'device_id', 'thread_id', 'kind', 'request'} or value['kind'] not in ('assistant', 'meal') or not identifier(value['device_id']) or not identifier(value['thread_id']):
                raise JobError('request_rejected')
            payload = value['request']
            if not isinstance(payload, dict) or not identifier(payload.get('request_id')):
                raise JobError('request_rejected')
            if value['kind'] == 'meal':
                meal_agent.validate_input(payload)
            else:
                if len(json.dumps(payload, ensure_ascii=False).encode()) > 65536 or payload.get('contract_version') != 2:
                    raise JobError('request_rejected')
                assistant_coach.validate_input(payload)
            deepseek_agent.options(payload)
            gateway.selected_model(payload)
            if not gateway.configured():
                return reply(503, {'error': 'provider_not_configured'})
            runner.store.submit(payload['request_id'], current, value['device_id'], value['thread_id'], value['kind'], payload, charge_request)
            return reply(200, runner.store.status(payload['request_id'], current))
        except JobError as error:
            code = str(error)
            return reply({'not_found': 404, 'queue_full': 429, 'rate_limited': 429, 'idempotency_conflict': 409}.get(code, 422), {'error': code})
        except (ValueError, KeyError, TypeError):
            return reply(422, {'error': 'request_rejected'})
        except OverflowError:
            return reply(413, {'error': 'request_too_large'})
        except Exception:
            return reply(503, {'error': 'job_store_unavailable'})

    return capabilities
