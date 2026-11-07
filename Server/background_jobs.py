"""Private, bounded jobs independent of a phone's HTTP connection.

Only encrypted short-lived input/results are persisted. Restarted running jobs
fail explicitly: paid model work is never silently replayed.
"""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
from cryptography.fernet import Fernet


class JobError(ValueError):
    pass


class JobStore:
    def __init__(self, path, key_path, clock=time.time, retention=86400):
        self.path = Path(path)
        self.clock = clock
        self.retention = retention
        self.path.parent.mkdir(parents=True, exist_ok=True)
        key_path = Path(key_path)
        key_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(Fernet.generate_key())
                stream.flush()
                os.fsync(stream.fileno())
        self.cipher = Fernet(key_path.read_bytes())
        with self.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, owner TEXT NOT NULL, device TEXT NOT NULL,
                thread TEXT NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL,
                state TEXT NOT NULL, created REAL NOT NULL, expires REAL NOT NULL,
                payload BLOB, result BLOB, preview BLOB, stage TEXT NOT NULL DEFAULT 'queued',
                error TEXT, notification TEXT NOT NULL DEFAULT 'unavailable')''')
        os.chmod(self.path, 0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=3)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA secure_delete=ON')
        return db

    def pack(self, value):
        return self.cipher.encrypt(json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode())

    def unpack(self, value):
        return json.loads(self.cipher.decrypt(value)) if value else None

    def prune(self):
        now = self.clock()
        with self.connect() as db:
            db.execute("UPDATE jobs SET state='failed',payload=NULL,preview=NULL,error='timeout' WHERE state IN ('queued','running') AND created<?", (now - 1000,))
            db.execute("UPDATE jobs SET state='expired',payload=NULL,result=NULL,preview=NULL,error='expired',notification='suppressed' WHERE expires<=? AND state!='expired'", (now,))
            db.execute('DELETE FROM jobs WHERE expires<?', (now - self.retention,))

    def recover(self, owner):
        self.prune()
        with self.connect() as db:
            # Rotating the single-owner credential also revokes old queued work.
            db.execute('DELETE FROM jobs WHERE owner!=?', (owner,))
            db.execute("UPDATE jobs SET state='failed',payload=NULL,preview=NULL,error='server_restarted' WHERE state='running'")

    def submit(self, job_id, owner, device, thread, kind, payload, charge_request):
        self.prune()
        encoded = json.dumps([device, thread, kind, payload], sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
        fingerprint = hashlib.sha256(encoded).hexdigest()
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT owner,fingerprint,state FROM jobs WHERE id=?', (job_id,)).fetchone()
            if row:
                if row['owner'] != owner or (row['fingerprint'] != fingerprint and row['fingerprint'] != 'cancelled-before-submit'):
                    raise JobError('idempotency_conflict')
                return False
            count = db.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running')").fetchone()[0]
            if count >= 4:
                raise JobError('queue_full')
            if not charge_request():
                raise JobError('rate_limited')
            now = self.clock()
            db.execute('''INSERT INTO jobs(id,owner,device,thread,kind,fingerprint,state,created,expires,payload)
                VALUES(?,?,?,?,?,?,'queued',?,?,?)''', (job_id, owner, device, thread, kind, fingerprint, now, now + self.retention, self.pack(payload)))
        return True

    def status(self, job_id, owner):
        self.prune()
        with self.connect() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=? AND owner=?', (job_id, owner)).fetchone()
        if not row:
            raise JobError('not_found')
        value = dict(job_id=row['id'], kind=row['kind'], state=row['state'], stage=row['stage'],
                     expires_at=row['expires'], notification=row['notification'])
        if row['preview']:
            value['preview'] = self.unpack(row['preview'])
        if row['result']:
            value['response'] = self.unpack(row['result'])
        if row['error']:
            value['error'] = row['error']
        return value

    def queued(self):
        self.prune()
        with self.connect() as db:
            return [row['id'] for row in db.execute("SELECT id FROM jobs WHERE state='queued' ORDER BY created LIMIT 4")]

    def claim(self, job_id):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT * FROM jobs WHERE id=? AND state='queued'", (job_id,)).fetchone()
            if not row:
                return None
            db.execute("UPDATE jobs SET state='running',stage='responding' WHERE id=?", (job_id,))
            return dict(row, payload=self.unpack(row['payload']))

    def progress(self, job_id, stage=None, preview=None):
        with self.connect() as db:
            if stage in ('thinking', 'responding', 'searching', 'reading', 'summarizing'):
                db.execute("UPDATE jobs SET stage=? WHERE id=? AND state='running'", (stage, job_id))
            if isinstance(preview, str) and len(preview) <= 1800:
                db.execute("UPDATE jobs SET preview=? WHERE id=? AND state='running'", (self.pack(preview), job_id))

    def finish(self, job_id, result=None, error=None):
        if result is not None and len(json.dumps(result, ensure_ascii=False).encode()) > 256000:
            result = None
            error = 'invalid_response'
        with self.connect() as db:
            return db.execute("UPDATE jobs SET state=?,payload=NULL,preview=NULL,result=?,error=? WHERE id=? AND state='running'",
                              ('completed' if result is not None else 'failed', self.pack(result) if result is not None else None, error, job_id)).rowcount == 1

    def cancel(self, job_id, owner):
        with self.connect() as db:
            count = db.execute("UPDATE jobs SET state='cancelled',payload=NULL,result=NULL,preview=NULL,error=NULL,notification='suppressed' WHERE id=? AND owner=? AND state NOT IN ('acknowledged','expired')", (job_id, owner)).rowcount
            if not count and not db.execute('SELECT id FROM jobs WHERE id=?', (job_id,)).fetchone():
                now = self.clock()
                db.execute("INSERT INTO jobs(id,owner,device,thread,kind,fingerprint,state,created,expires,notification) VALUES(?,?, '', '', 'assistant','cancelled-before-submit','cancelled',?,?,'suppressed')", (job_id, owner, now, now + self.retention))
            elif not count and not db.execute('SELECT id FROM jobs WHERE id=? AND owner=?', (job_id, owner)).fetchone():
                raise JobError('not_found')

    def acknowledge(self, job_id, owner):
        with self.connect() as db:
            db.execute("UPDATE jobs SET state='acknowledged',payload=NULL,result=NULL,preview=NULL,notification='suppressed' WHERE id=? AND owner=? AND state IN ('completed','failed')", (job_id, owner))
        return self.status(job_id, owner)



class JobRunner:
    def __init__(self, store, owner, generate, slots):
        self.store, self.owner, self.generate, self.slots = store, owner, generate, slots
        self.workers = {}
        self.pump = None

    async def start(self):
        self.store.recover(self.owner)
        self.pump = asyncio.create_task(self.run())

    async def close(self):
        if self.pump:
            self.pump.cancel()
        tasks = list(self.workers.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, *([self.pump] if self.pump else []), return_exceptions=True)

    async def run(self):
        while True:
            for job_id in self.store.queued():
                if not self.slots.acquire(blocking=False):
                    break
                try:
                    job = self.store.claim(job_id)
                except Exception:
                    self.slots.release()
                    raise
                if not job:
                    self.slots.release()
                    continue
                task = asyncio.create_task(self.work(job))
                self.workers[job_id] = task
                task.add_done_callback(lambda _, key=job_id: self.workers.pop(key, None))
            await asyncio.sleep(0.25)

    async def work(self, job):
        job_id = job['id']
        response = None
        last_preview = 0.0

        async def emit(kind, **fields):
            nonlocal response, last_preview
            if kind == 'result':
                response = fields['response']
            elif kind == 'status':
                self.store.progress(job_id, stage=fields.get('stage'))
            elif kind == 'message' and time.monotonic() - last_preview >= 0.2:
                self.store.progress(job_id, preview=fields.get('text'))
                last_preview = time.monotonic()

        try:
            if self.store.clock() - job['created'] > 600:
                raise JobError('queue_timeout')
            await asyncio.wait_for(self.generate(job['payload'], emit, meal=job['kind'] == 'meal'), 305)
            self.store.finish(job_id, result=response, error=None if response is not None else 'incomplete_response')
        except asyncio.CancelledError:
            self.store.finish(job_id, error='server_interrupted')
            raise
        except Exception as error:
            code = str(error)
            allowed = {'budget_exhausted', 'limiter_unavailable', 'queue_timeout', 'incomplete_response', 'uncommitted_write_claim', 'web_provider_unavailable'}
            self.store.finish(job_id, error='timeout' if isinstance(error, asyncio.TimeoutError) else code if code in allowed else 'provider_unavailable')
        finally:
            self.slots.release()

    def cancel(self, job_id, owner):
        self.store.cancel(job_id, owner)
        task = self.workers.get(job_id)
        if task:
            task.cancel()
