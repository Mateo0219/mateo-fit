"""Content-free usage accounting; quotas are disabled unless explicitly set."""
import os
from pathlib import Path
import sqlite3
import threading
from datetime import datetime, timezone

_lock = threading.Lock()

class BudgetError(ValueError):
    pass

def limit(name):
    """-1 means unlimited. Zero remains an explicitly configured stop."""
    return int(os.environ.get(name, '-1'))

def policy():
    names = {'provider_calls_per_day': 'XUXU_MAX_DAILY_PROVIDER_CALLS',
             'requests_per_day': 'XUXU_MAX_DAILY_REQUESTS',
             'requests_per_minute': 'XUXU_MAX_MINUTE_REQUESTS'}
    return {key: value if (value := limit(name)) >= 0 else None for key, name in names.items()}

def allowed():
    maximum = limit('XUXU_MAX_DAILY_PROVIDER_CALLS')
    try:
        return record_attempt(maximum)
    except Exception:
        if maximum < 0:
            # Accounting is optional when no quota was requested.
            return True
        raise

def record_attempt(maximum):
    day = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    dbpath = Path(os.environ.get('XUXU_LIMIT_DB', '/data/limits.sqlite3'))
    dbpath.parent.mkdir(parents=True, exist_ok=True)
    with _lock, sqlite3.connect(dbpath, timeout=3) as db:
        db.execute('CREATE TABLE IF NOT EXISTS provider_counters (day TEXT PRIMARY KEY, count INTEGER NOT NULL)')
        db.execute('BEGIN IMMEDIATE')
        count = (db.execute('SELECT count FROM provider_counters WHERE day=?', (day,)).fetchone() or [0])[0]
        if maximum >= 0 and count >= maximum:
            return False
        db.execute('INSERT INTO provider_counters VALUES (?,1) ON CONFLICT(day) DO UPDATE SET count=count+1', (day,))
        db.execute('DELETE FROM provider_counters WHERE day != ?', (day,))
    return True

def consume(charge=None):
    """Reserve exactly once immediately before a network attempt; failures count too."""
    try:
        permitted = (charge or allowed)()
    except Exception as error:
        raise BudgetError('limiter_unavailable') from error
    if not permitted:
        raise BudgetError('budget_exhausted')
