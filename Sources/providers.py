"""Local, read-only adapters for the first-batch AI clients.

No client credentials, cookies, or encrypted stores are read. Completion is
derived from explicit lifecycle events, never from a quiet process or file.
"""
from contextlib import closing
from datetime import datetime
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import time
from urllib.parse import quote, urlencode


PRODUCTS = {
    'codex': ('Codex', ('Codex', 'ChatGPT'), '原生任务'),
    'claude': ('Claude Code', ('Claude',), '事件接入'),
    'cursor': ('Cursor', ('Cursor',), '事件接入'),
    'copilot': ('GitHub Copilot', ('GitHub Copilot', 'Visual Studio Code'), '事件接入'),
    'antigravity': ('Antigravity', ('Antigravity',), '事件接入'),
    'gemini': ('Gemini CLI / Code Assist', (), '事件接入'),
    'windsurf': ('Windsurf / Devin', ('Windsurf', 'Devin', 'Devin Desktop'), '事件接入'),
    'opencode': ('OpenCode', ('OpenCode', 'opencode'), '事件接入 + 本地会话'),
    'trae': ('TRAE', ('Trae', 'Trae CN', 'TRAE'), '事件接入'),
    'codebuddy': ('CodeBuddy', ('CodeBuddy CN', 'CodeBuddy'), '原生任务 + 事件'),
    'qoder': ('Qoder / Qoder CN', ('Qoder', 'Qoder CN', 'Lingma'), '事件接入'),
    'qwencode': ('Qwen Code', (), '事件接入'),
    'qianwen': ('千问「工作」', ('Qianwen', '千问'), '本地任务'),
    'deepseek': ('DeepSeek Harness', ('DeepSeek Harness',), '原生任务'),
    'minimax': ('MiniMax Agent / Code', ('MiniMax Code', 'MiniMax Agent', 'MiniMax'), '原生任务'),
    'kimi': ('Kimi Code', (), '事件接入'),
}


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(path)


def database(path):
    # mode=ro includes live WAL contents; immutable=1 would silently miss them.
    return sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.2)


def task(provider, session, turn, title, status, **extra):
    return dict(id=provider + ':' + str(session), session=str(session), provider=provider,
                source=PRODUCTS[provider][0], turn=str(turn), title=' '.join(str(title or PRODUCTS[provider][0]).split())[:200],
                status=status, **extra)


def parse_timestamp(value):
    if value is None or value == '':
        return 0
    try:
        number = float(value)
        return number / 1000 if number > 100000000000 else number
    except (ValueError, TypeError):
        try:
            text = str(value).strip().replace('Z', '+00:00')
            if ' ' in text and 'T' not in text:
                text = text.replace(' ', 'T', 1)
            text = re.sub(r'\.(\d+)', lambda match: '.' + (match.group(1) + '000000')[:6], text)
            return datetime.fromisoformat(text).timestamp()
        except ValueError:
            return 0


def reconcile_antigravity_tasks(home, history, entries=None):
    tasks = [(key, entry) for key, entry in list(history.items()) if entry.get('provider') == 'antigravity']
    path = home / '.gemini/antigravity/conversation_summaries.db'
    if not tasks or not path.is_file():
        return
    running_sessions = []
    if entries is not None:
        running_sessions = [entry['session'] for entry in entries.values()
                            if entry.get('provider') == 'antigravity' and entry.get('status') == 'running' and entry.get('session')]

    def load(connection):
        columns = {row[1] for row in connection.execute('PRAGMA table_info(conversation_summaries)')}
        if 'nesting_depth' in columns:
            child_query = (
                "SELECT conversation_id, parent_conversation_id, COALESCE(nesting_depth, 0) "
                "FROM conversation_summaries "
                "WHERE (parent_conversation_id IS NOT NULL AND parent_conversation_id <> '') "
                "OR COALESCE(nesting_depth, 0) > 0"
            )
        else:
            child_query = (
                "SELECT conversation_id, parent_conversation_id, 0 "
                "FROM conversation_summaries "
                "WHERE parent_conversation_id IS NOT NULL AND parent_conversation_id <> ''"
            )
        children = {
            cid for cid, parent, depth in connection.execute(child_query)
            if (parent and parent != cid) or (depth and depth > 0)
        }
        states = {}
        remaining_running = [cid for cid in running_sessions if cid not in children]
        if remaining_running and {'status', 'not_fully_idle', 'killed'}.issubset(columns):
            modified_col = 'last_modified_time' if 'last_modified_time' in columns else "''"
            placeholders = ','.join('?' for _ in remaining_running)
            state_query = (f"SELECT conversation_id, status, not_fully_idle, killed, {modified_col} "
                           f"FROM conversation_summaries WHERE conversation_id IN ({placeholders})")
            for cid, db_status, not_fully_idle, killed, modified in connection.execute(state_query, remaining_running):
                states[cid] = (db_status, not_fully_idle, killed, modified)
        return children, states

    try:
        with closing(database(path)) as connection:
            children, states = load(connection)
    except sqlite3.Error:
        # SQLite can refuse a read-only open of an idle WAL-mode database
        # whose client removed the sidecars. Never ignore an existing WAL.
        wal = path.with_name(path.name + '-wal')
        if wal.exists():
            return
        try:
            before = path.stat()
            with closing(sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
                children, states = load(connection)
            if wal.exists() or path.stat().st_mtime_ns != before.st_mtime_ns:
                return
        except (OSError, sqlite3.Error):
            return
    for key, entry in tasks:
        if entry.get('session') in children:
            history.pop(key, None)
            if entries is not None:
                entries.pop(key, None)
    if entries is not None and states:
        now = time.time()
        for key, entry in list(entries.items()):
            if entry.get('provider') != 'antigravity' or entry.get('status') != 'running':
                continue
            state = states.get(entry.get('session'))
            if not state:
                continue
            db_status, not_fully_idle, killed, modified = state
            idle = bool(killed) or (db_status == 'CASCADE_RUN_STATUS_IDLE' and not not_fully_idle)
            if not idle:
                continue
            event_ts = parse_timestamp(entry.get('updated'))
            modified_ts = parse_timestamp(modified)
            if bool(killed) or modified_ts >= event_ts - 2 or (event_ts and now - event_ts >= 5):
                entry['status'] = 'stopped'
                entries.pop(key, None)


def _deepseek_visible_sessions(home):
    """Return session IDs visible in DeepSeek Harness desktop workspaces, or None if unavailable."""
    path = home / '.dsh/storages/workspace.json'
    if not path.is_file():
        return None
    data = read_json(path)
    if not isinstance(data, dict):
        return None
    workspaces = data.get('tables', {}).get('workspaces')
    if not isinstance(workspaces, dict):
        return None
    visible = set()
    for workspace in workspaces.values():
        if isinstance(workspace, dict):
            for sid in workspace.get('sessionIds', ()):
                if isinstance(sid, str) and sid:
                    visible.add(sid)
    archived = {
        sid for sid in data.get('global', {}).get('archivedSessionIds', ())
        if isinstance(sid, str) and sid
    }
    return visible - archived


def deepseek_tasks(home):
    root = home / '.dsh/storages/session_projcache/sessions'
    visible = _deepseek_visible_sessions(home)
    cospan_jobs = None
    result = []
    for path in root.glob('session-*.json'):
        record = read_json(path, {}).get('record', {})
        rows = record.get('rows', {})
        def value(key, default=None):
            return rows.get(key, {}).get('val', default)
        if value('parentSessionId') or value('parent_session_id') or value('isSubagent'):
            continue
        if visible is not None and path.stem not in visible:
            if cospan_jobs is None:
                cospan_jobs = load_cospan_jobs(home)
            title = str(value('title') or '').lower()
            if f'deepseek:{path.stem}' not in cospan_jobs and '[cospan delegation context]' not in title:
                continue
        boundary = value('turnBoundary', {})
        questions = value('userQuestions', {}).get('questions', {}).get('active', [])
        open_turn = boundary.get('openTurnStartSeq')
        last_boundary = boundary.get('lastStepBoundary') or {}
        if questions:
            status = 'waiting'
        elif open_turn is not None:
            status = 'running'
        elif last_boundary.get('kind') == 'end':
            status = 'completed'
        else:
            status = 'stopped'
        # lastTurn is assigned at turn/start and retained at turn/end.
        turn = str(boundary.get('lastTurn', 0))
        result.append(task('deepseek', path.stem, turn, value('title'), status,
                           app='DeepSeek Harness', navigation='application', updated=path.stat().st_mtime,
                           waiting_kind='question' if questions else ''))
    return result


def minimax_tasks(home):
    path = home / '.minimax/v2/sqlite/runtime-state.sqlite'
    if not path.exists():
        return []
    result = []
    with database(path) as connection:
        tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT session_id,title,status,archived,visibility,parent_session_id,updated_at_ms FROM local_runtime_sessions")
        for row in rows:
            if row['archived'] or row['visibility'] != 'visible' or row['parent_session_id']:
                continue
            latest = connection.execute('SELECT turn_id,role,data_json FROM local_runtime_message_rows WHERE session_id=? ORDER BY id DESC LIMIT 1', (row['session_id'],)).fetchone()
            if not latest:
                continue
            message = json.loads(latest['data_json'])
            turn = latest['turn_id'] or message.get('turnId') or message.get('query_key', '')
            raw = row['status']
            status = {'started': 'running', 'running': 'running', 'busy': 'running', 'streaming': 'running',
                      'waiting_permission': 'waiting', 'waiting_input': 'waiting',
                      'waiting': 'waiting', 'aborted': 'stopped', 'interrupted': 'stopped',
                      'error': 'stopped', 'failed': 'stopped'}.get(raw, 'stopped')
            # Idle only means completion when there is an actual final reply.
            if raw == 'idle' and latest['role'] == 'assistant' and message.get('finish_reason') in ('stop', 'end_turn'):
                status = 'completed'
            if 'local_runtime_turn_ingress' in tables:
                ingress = connection.execute('SELECT turn_id,status FROM local_runtime_turn_ingress WHERE session_id=? ORDER BY accepted_at_ms DESC LIMIT 1', (row['session_id'],)).fetchone()
                if ingress:
                    turn = ingress['turn_id']
                    status = {'accepted': 'running', 'completed': 'completed', 'failed': 'stopped', 'aborted': 'stopped'}.get(ingress['status'], status)
            if 'questionnaire_requests' in tables:
                pending = connection.execute("SELECT 1 FROM questionnaire_requests WHERE session_id=? AND status='pending' AND answered_at IS NULL AND dismissed_at IS NULL LIMIT 1", (row['session_id'],)).fetchone()
                if pending:
                    status = 'waiting'
            result.append(task('minimax', row['session_id'], turn, row['title'], status,
                               app='MiniMax Code', navigation='application', updated=(row['updated_at_ms'] or 0) / 1000))
    return result


def codebuddy_tasks(home):
    result = []
    for folder, app in [('CodeBuddy CN', 'CodeBuddy CN'), ('CodeBuddy', 'CodeBuddy')]:
        path = home / 'Library/Application Support' / folder / 'codebuddy-sessions.vscdb'
        if not path.exists():
            continue
        with database(path) as connection:
            for key, encoded in connection.execute("SELECT key,value FROM ItemTable WHERE key LIKE 'session:%'"):
                data = json.loads(encoded)
                if data.get('deletedAt') is not None or data.get('parentConversationId') or data.get('parentId') or data.get('isSubagent'):
                    continue
                status = {'Completed': 'completed', 'Running': 'running', 'InProgress': 'running',
                          'Working': 'running', 'Planning': 'running', 'Pending': 'running',
                          'WaitingForUser': 'waiting', 'WaitingForApproval': 'waiting',
                          'Cancelled': 'stopped', 'Error': 'stopped', 'Failed': 'stopped', 'Terminated': 'stopped'}.get(data.get('status'), 'stopped')
                # The timestamp changes within a running turn. UnifiedMonitor
                # pins it until the transition to a terminal state.
                result.append(task('codebuddy', data['conversationId'], data.get('updatedAt', ''),
                                   data.get('title'), status, app=app, navigation='application', updated=data.get('updatedAt', 0)))
    return result


def opencode_tasks(home):
    """OpenCode v1's documented SQLite store. Unknown schemas fail visibly."""
    path = home / '.local/share/opencode/opencode.db'
    if not path.exists():
        return []
    result = []
    with database(path) as connection:
        tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'session' not in tables:
            return []  # OpenCode V2 uses the event plugin, not the V1 schema.
        for sid, title in connection.execute('SELECT id,title FROM session WHERE parent_id IS NULL AND time_archived IS NULL'):
            rows = connection.execute('SELECT id,data FROM message WHERE session_id=? ORDER BY time_created DESC LIMIT 2', (sid,)).fetchall()
            if not rows:
                continue
            mid, encoded = rows[0]
            data = json.loads(encoded)
            status = 'stopped'
            if data.get('role') == 'user':
                status = 'running'
            elif data.get('role') == 'assistant':
                status = 'completed' if data.get('time', {}).get('completed') and data.get('finish') not in ('tool-calls', None) else 'running'
                if data.get('error'):
                    status = 'stopped'
            result.append(task('opencode', sid, data.get('parentID', mid), title, status,
                               app='OpenCode', navigation='application', updated=data.get('time', {}).get('created', 0) / 1000))
    return result


def qianwen_session_indexes(home):
    root = home.resolve() / 'Library/Application Support/Qianwen/qwen-agent'
    return root.glob('*/projects/*/sessions/sessions.json')


def qianwen_process_start():
    result = subprocess.run(['/bin/ps', '-axo', 'lstart=,comm='], capture_output=True, text=True,
                            errors='replace', check=True, timeout=1, env=dict(os.environ, LC_ALL='C'))
    starts = [datetime.strptime(line[:24], '%a %b %d %H:%M:%S %Y').timestamp()
              for line in result.stdout.splitlines()
              if line[24:].strip().endswith('/Contents/MacOS/Qianwen')]
    return max(starts, default=float('inf'))


def qianwen_event_lines(path, size):
    """Read complete JSONL rows backwards, ignoring an append in progress."""
    with path.open('rb') as handle:
        position, suffix = size, b''
        discard_tail = True
        while position:
            start = max(0, position - 65536)
            handle.seek(start)
            rows = (handle.read(position - start) + suffix).split(b'\n')
            if discard_tail and len(rows) > 1:
                rows.pop()
                discard_tail = False
            suffix = rows.pop(0) if start else b''
            if not discard_tail:
                yield from reversed(rows)
            position = start


@lru_cache(maxsize=1024)
def qianwen_turn(path, thread, signature):
    terminal = {}
    prompts = set()
    settled = set()
    latest_tool_activity = {}
    for line in qianwen_event_lines(path, signature[-1]):
        # The journal also carries message bodies and tool output. Only use
        # lifecycle events and identifiers for matching questions to answers.
        if not any(marker in line for marker in (b'"turn_started"', b'"turn_completed"', b'"tool-call"', b'"tool-output"')):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get('threadId') != thread or event.get('schemaVersion') != 2:
            continue
        kind, turn = event.get('type'), event.get('turnId')
        if not isinstance(turn, str) or not turn:
            continue
        if kind == 'turn_started':
            if turn in terminal:
                return turn, *terminal[turn]
            waiting = any(owner == turn for owner, _ in prompts)
            return turn, 'waiting' if waiting else 'running', latest_tool_activity.get(turn, event['timestamp'])
        if kind == 'turn_completed':
            status = 'completed' if event['payload'].get('status') == 'completed' else 'stopped'
            terminal.setdefault(turn, (status, event['timestamp']))
        if kind == 'canonical_item' and event.get('scope') == 'main' and turn not in terminal:
            item = event['payload']['item']
            key = (turn, item.get('callId'))
            if not key[1]:
                continue
            if item.get('kind') == 'tool-output':
                settled.add(key)
            elif item.get('kind') == 'tool-call' and item.get('toolName') == 'AskUserQuestion' and key not in settled:
                prompts.add(key)
            latest_tool_activity.setdefault(turn, event['timestamp'])
    return None


def qianwen_tasks(home):
    result = []
    process_start = None
    for index in qianwen_session_indexes(home):
        project = index.parents[1].name
        account = index.parents[3].name
        if index.resolve() != index or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', project):
            continue
        data = json.loads(index.read_text())
        if data.get('schemaVersion') != 1 or not isinstance(data.get('threads'), list):
            raise ValueError('无法识别千问工作任务索引格式')
        for record in data['threads']:
            thread = record.get('id')
            if (not isinstance(thread, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', thread)
                    or record.get('projectId') != project or record.get('archived') or record.get('sessionType') == 'voice'
                    or record.get('parentId') or record.get('parentThreadId')):
                continue
            journal = index.parent / thread / 'thread-events.jsonl'
            if journal.resolve() != journal:
                continue
            try:
                info = journal.stat()
                signature = (info.st_ino, info.st_mtime_ns, info.st_size)
                latest = qianwen_turn(journal, thread, signature)
            except FileNotFoundError:
                continue
            if latest is None:
                continue
            turn, status, timestamp = latest
            updated = datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()
            if status in ('running', 'waiting'):
                if process_start is None:
                    try:
                        process_start = qianwen_process_start()
                    except subprocess.SubprocessError:
                        process_start = float('inf')
                if updated < process_start:
                    status = 'stopped'
            url = 'https://www.qianwen.com/chat/workbench?' + urlencode(dict(taskid=thread, projectid=project))
            result.append(task('qianwen', f'{account}:{project}:{thread}', turn, record.get('title'), status,
                               app='Qianwen', bundle_id='com.alibaba.tongyi', navigation='session',
                               open_url=url, updated=updated, waiting_kind='question' if status == 'waiting' else ''))
            result[-1]['source'] = '千问'
    return result


NATIVE = {'deepseek': deepseek_tasks, 'minimax': minimax_tasks,
          'codebuddy': codebuddy_tasks, 'opencode': opencode_tasks, 'qianwen': qianwen_tasks}


def _file_sig(path):
    try:
        st = path.stat()
        return (st.st_ino, st.st_size, st.st_mtime_ns)
    except OSError:
        return None


def _db_sig(path):
    return (_file_sig(path), _file_sig(path.with_name(path.name + '-wal')))


def _native_provider_sig(provider, home):
    if provider == 'minimax':
        return _db_sig(home / '.minimax/v2/sqlite/runtime-state.sqlite')
    if provider == 'codebuddy':
        return tuple(
            _db_sig(home / 'Library/Application Support' / folder / 'codebuddy-sessions.vscdb')
            for folder in ('CodeBuddy CN', 'CodeBuddy')
        )
    if provider == 'opencode':
        return _db_sig(home / '.local/share/opencode/opencode.db')
    if provider == 'deepseek':
        root = home / '.dsh/storages/session_projcache/sessions'
        if not root.exists():
            return None
        ws_sig = _file_sig(home / '.dsh/storages/workspace.json')
        sessions_sig = tuple(sorted((p.name, _file_sig(p)) for p in root.glob('session-*.json')))
        return (ws_sig, _cospan_sig(home), sessions_sig)
    if provider == 'qianwen':
        sigs = []
        for idx in qianwen_session_indexes(home):
            sigs.append((str(idx), _file_sig(idx)))
            for j in idx.parent.glob('*/thread-events.jsonl'):
                sigs.append((str(j), _file_sig(j)))
        return tuple(sorted(sigs))
    return None


COSPAN_TARGET_PROVIDER = {
    'agy': 'antigravity',
    'antigravity': 'antigravity',
    'dsh': 'deepseek',
    'deepseek': 'deepseek',
    'claude': 'claude',
    'codex': 'codex',
    'gemini': 'gemini',
    'opencode': 'opencode',
    'qwen': 'qwencode',
    'qwencode': 'qwencode',
    'kimi': 'kimi',
    'cursor': 'cursor',
    'codebuddy': 'codebuddy',
    'minimax': 'minimax',
}

COSPAN_STOPPED_STATUSES = {'canceled', 'cancelled', 'failed', 'timeout', 'error', 'aborted'}


def _cospan_sig(home):
    root = home / '.cospan/trajectories'
    if not root.exists():
        return None
    return tuple(sorted((str(p), _file_sig(p)) for p in root.glob('*/state.json')))


def load_cospan_jobs(home):
    root = home / '.cospan/trajectories'
    if not root.exists():
        return {}
    by_task_id = {}
    for path in sorted(root.glob('*/state.json')):
        data = read_json(path, {})
        if not isinstance(data, dict):
            continue
        for job in data.get('jobs', ()):
            if not isinstance(job, dict):
                continue
            job_id = job.get('id')
            conv = job.get('conversation_id')
            if not job_id or not conv:
                continue
            target = str(job.get('target') or '').lower()
            provider = COSPAN_TARGET_PROVIDER.get(target, target)
            if not provider:
                continue
            task_id = str(conv) if provider == 'codex' else f'{provider}:{conv}'
            started = parse_timestamp(job.get('started_at'))
            previous = by_task_id.get(task_id)
            if previous and previous.get('started', 0) > started:
                continue
            by_task_id[task_id] = {
                'id': str(job_id),
                'target': target,
                'provider': provider,
                'status': str(job.get('status') or '').lower(),
                'model': str(job.get('model') or ''),
                'cwd': str(job.get('cwd') or ''),
                'caller_session_id': str(job.get('caller_session_id') or ''),
                'started': started,
            }
    return by_task_id


def _is_cospan_entry(key, entry, cospan_jobs):
    if key in cospan_jobs:
        return True
    title = str(entry.get('title') or '').lower()
    return '[cospan delegation context]' in title


def _cospan_subtask_title(entry, job):
    title = str(entry.get('title') or '')
    if '[cospan delegation context]' not in title.lower():
        return title
    source = entry.get('source') or PRODUCTS.get(entry.get('provider'), ('协同子任务',))[0]
    model = (job or {}).get('model') or ''
    if '/' in model:
        model = model.rsplit('/', 1)[-1]
    return f'{source} · {model}' if model else f'{source} 协同子任务'


def reconcile_cospan_statuses(cospan_jobs, history, entries):
    if not cospan_jobs:
        return
    for key, entry in list(entries.items()):
        job = cospan_jobs.get(key)
        if not job:
            continue
        job_status = job.get('status')
        if job_status in COSPAN_STOPPED_STATUSES and entry.get('status') in ('running', 'completed'):
            entry['status'] = 'stopped'
            entries.pop(key, None)
            if key in history:
                history[key]['status'] = 'stopped'
        elif job_status == 'done' and entry.get('status') == 'running':
            entry['status'] = 'completed'
            if key in history:
                history[key]['status'] = 'completed'


def _find_cospan_parent(key, entry, pool, cospan_jobs, job_owners, updated_fn):
    if not _is_cospan_entry(key, entry, cospan_jobs):
        return None
    job = cospan_jobs.get(key)
    if job:
        caller = job.get('caller_session_id')
        if caller and caller != key and caller in pool:
            return caller
        owner = job_owners.get(job['id'])
        if owner and owner != key and owner in pool:
            return owner
        # If this job has a known owner that is NOT in `pool`, don't misattribute it to another thread.
        if owner or caller:
            return None
    # Fallback for brand-new cospan tasks before job_id/conversation_id links appear:
    # match active Codex parent in the same project (preferring $prod-rd / cospan threads).
    project = entry.get('project') or (Path(job['cwd']).name if job and job.get('cwd') else '')
    if not project:
        return None
    candidates = [
        (pid, pentry) for pid, pentry in pool.items()
        if pid != key and pentry.get('provider') == 'codex' and pentry.get('project') == project
    ]
    if not candidates:
        return None
    def rank(item):
        _, pentry = item
        title = str(pentry.get('title') or '').lower()
        is_collab = 1 if ('$prod-rd' in title or 'cospan' in title) else 0
        return (is_collab, updated_fn(pentry))
    candidates.sort(key=rank, reverse=True)
    return candidates[0][0]


class UnifiedMonitor:
    def __init__(self, data, codex=None, home=None):
        self.data = Path(data)
        self.data.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.home = Path(home) if home else Path.home()
        self.codex = codex
        self.entries = {}
        self.history = []
        self.last_output = None
        self.native = read_json(self.data / 'native-state.json', {})
        self.source_errors = {}
        self.last_discovery = 0
        self.started = time.time()
        self.installed = {}
        self._event_cache = {}
        self._native_sig_cache = {}
        self._native_tasks_cache = {}
        self._dismissed_sig = None
        self._dismissed_cache = {}
        self._integrations_sig = None
        self._integrations_cache = {}
        self._settings_sig = None
        self._disabled_providers = set()
        self._ag_db_sig = None
        self._cospan_sig = None
        self._cospan_jobs_cache = {}
        self._installed_changed = True

    def discover(self):
        if time.time() - self.last_discovery < 30:
            return
        self.last_discovery = time.time()
        roots = [Path('/Applications'), self.home / 'Applications']
        new_installed = {key: [str(root / (name + '.app')) for root in roots for name in names if (root / (name + '.app')).exists()]
                         for key, (_, names, _) in PRODUCTS.items()}
        if new_installed != self.installed:
            self.installed = new_installed
            self._installed_changed = True

    def tick(self):
        self.discover()
        any_changed = self.last_output is None or self._installed_changed
        self._installed_changed = False

        dismissed_sig = _file_sig(self.data / 'dismissed.json')
        if dismissed_sig != self._dismissed_sig:
            self._dismissed_cache = read_json(self.data / 'dismissed.json', {})
            self._dismissed_sig = dismissed_sig
            any_changed = True
        dismissed = self._dismissed_cache

        integrations_sig = _file_sig(self.data / 'integrations.json')
        if integrations_sig != self._integrations_sig:
            self._integrations_cache = read_json(self.data / 'integrations.json', {})
            self._integrations_sig = integrations_sig
            any_changed = True
        installed_hooks = self._integrations_cache

        settings_sig = _file_sig(self.data / 'settings.json')
        if settings_sig != self._settings_sig:
            settings_data = read_json(self.data / 'settings.json', {})
            raw_disabled = settings_data.get('disabledProviders', []) if isinstance(settings_data, dict) else []
            self._disabled_providers = {str(p) for p in raw_disabled if isinstance(p, str)}
            self._settings_sig = settings_sig
            any_changed = True
        disabled_providers = self._disabled_providers

        # Check codex
        codex_tasks = []
        codex_error = None
        if self.codex and self.codex.database.exists():
            try:
                codex_tasks = self.codex.tick(publish=False)
                if getattr(self.codex, 'changed', True):
                    any_changed = True
            except (OSError, sqlite3.Error, ValueError) as error:
                codex_error = str(error)
                any_changed = True
        elif self.source_errors.get('codex'):
            any_changed = True

        # Check native providers with stat caching
        native_errors = {}
        for provider, collect in NATIVE.items():
            sig = _native_provider_sig(provider, self.home)
            if provider in self._native_sig_cache and self._native_sig_cache[provider] == sig and provider not in self.source_errors:
                continue
            try:
                self._native_tasks_cache[provider] = collect(self.home)
                self._native_sig_cache[provider] = sig
                any_changed = True
            except (OSError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
                native_errors[provider] = str(error)
                any_changed = True

        # Check event files with stat caching
        events_dir = self.data / 'events'
        current_event_files = set()
        if events_dir.exists():
            for path in events_dir.glob('*.json'):
                key_path = str(path)
                current_event_files.add(key_path)
                sig = _file_sig(path)
                cached = self._event_cache.get(key_path)
                if cached and cached[0] == sig:
                    continue
                entry = read_json(path)
                self._event_cache[key_path] = (sig, entry)
                any_changed = True
        for stale_key in list(self._event_cache):
            if stale_key not in current_event_files:
                del self._event_cache[stale_key]
                any_changed = True

        # Check if Antigravity DB changed while there are running/tracked antigravity tasks
        ag_db_sig = _db_sig(self.home / '.gemini/antigravity/conversation_summaries.db')
        if ag_db_sig != self._ag_db_sig:
            self._ag_db_sig = ag_db_sig
            any_changed = True
        elif any(e.get('provider') == 'antigravity' and e.get('status') == 'running' for e in self.entries.values()):
            any_changed = True

        cospan_sig = _cospan_sig(self.home)
        if cospan_sig != self._cospan_sig:
            self._cospan_jobs_cache = load_cospan_jobs(self.home)
            self._cospan_sig = cospan_sig
            any_changed = True
        cospan_jobs = self._cospan_jobs_cache

        # Fast path: nothing changed since last tick, just touch heartbeat!
        if not any_changed and (self.data / 'snapshot.json').exists():
            os.utime(self.data / 'snapshot.json', None)
            return

        entries, errors = {}, {}
        history = {}
        if codex_error:
            errors['codex'] = codex_error
            entries.update({k: dict(v, stale=True) for k, v in self.entries.items() if v.get('provider') == 'codex'})
        elif self.codex and self.codex.database.exists():
            for entry in self.codex.history:
                history[entry['id']] = dict(entry, provider='codex', source='Codex', navigation='session',
                                            open_url='codex://threads/' + quote(entry['id'], safe=''))
            for entry in codex_tasks:
                entry = dict(entry, provider='codex', source='Codex', navigation='session',
                             open_url='codex://threads/' + quote(entry['id'], safe=''))
                entries[entry['id']] = entry

        dirty = False
        native_present = set()
        for provider in NATIVE:
            if provider in native_errors:
                errors[provider] = native_errors[provider]
                entries.update({k: dict(v, stale=True) for k, v in self.entries.items() if v.get('provider') == provider})
                continue
            for current in self._native_tasks_cache.get(provider, ()):
                current = dict(current)
                key = current['id']
                history[key] = current
                native_present.add(key)
                previous = self.native.get(key)
                if provider == 'codebuddy' and previous:
                    if previous['status'] in ('running', 'waiting') or (previous['status'] == 'completed' and current['status'] == 'completed'):
                        current['turn'] = previous['turn']
                unseen = bool(previous and previous.get('unread'))
                if current['status'] == 'completed':
                    unseen = bool(previous and (unseen or previous['status'] in ('running', 'waiting') or previous['turn'] != current['turn']))
                    if provider == 'qianwen' and not previous:
                        unseen = current['updated'] >= self.started
                else:
                    unseen = False
                stored = dict(current, unread=unseen)
                if previous != stored:
                    self.native[key] = stored
                    dirty = True
                if current['status'] in ('running', 'waiting') or unseen:
                    entries[key] = current
        # Removed sessions are no longer candidates. Keep failed sources intact.
        for key in list(self.native):
            if key not in native_present and self.native[key]['provider'] not in errors:
                del self.native[key]
                dirty = True
        if dirty:
            atomic_json(self.data / 'native-state.json', self.native)
        hooks_seen = set()
        for _, entry in self._event_cache.values():
            if not isinstance(entry, dict) or entry.get('provider') not in PRODUCTS:
                continue
            entry = dict(entry)
            history[entry['id']] = entry
            if time.time() - entry.get('updated', 0) > 86400 and entry.get('status') in ('running', 'waiting'):
                continue  # A vanished client must not look busy forever.
            hooks_seen.add(entry['provider'])
            if entry.get('status') in ('running', 'waiting', 'completed'):
                # Event hooks have higher fidelity than local history.
                entries[entry['id']] = entry
            else:
                entries.pop(entry['id'], None)
        reconcile_antigravity_tasks(self.home, history, entries)
        reconcile_cospan_statuses(cospan_jobs, history, entries)
        if disabled_providers:
            entries = {k: v for k, v in entries.items() if v.get('provider') not in disabled_providers}
            history = {k: v for k, v in history.items() if v.get('provider') not in disabled_providers}
        for key, entry in history.items():
            if entry.get('navigation') == 'application' and self.installed.get(entry.get('provider')):
                entry['app'] = Path(self.installed[entry['provider']][0]).stem
        for key, entry in list(entries.items()):
            if entry.get('navigation') == 'application' and self.installed.get(entry.get('provider')):
                candidates = self.installed[entry['provider']]
                if not any(Path(candidate).stem == entry.get('app') for candidate in candidates):
                    entry['app'] = Path(candidates[0]).stem
            suffix = ':completed' if entry['status'] == 'completed' else (':running' if entry['status'] == 'running' else '')
            dismissal = entry['turn'] + suffix
            if dismissed.get(key) == dismissal:
                del entries[key]
        priority = {'waiting': 0, 'completed': 1, 'running': 2}
        fields = {'id', 'turn', 'title', 'status', 'provider', 'source', 'navigation', 'navigation_id', 'open_url',
                  'app', 'bundle_id', 'resume_command', 'waiting_kind', 'stale', 'project'}
        def updated(entry):
            value = entry.get('updated', 0)
            try:
                number = float(value)
                return number / 1000 if number > 100000000000 else number
            except (ValueError, TypeError):
                try:
                    return datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
                except ValueError:
                    return 0

        # Resolve cospan job -> parent Codex thread ownership when any cospan jobs exist.
        target_job_ids = {
            cospan_jobs[k]['id']
            for k in (set(entries) | set(history))
            if k in cospan_jobs
        }
        job_owners = {}
        if target_job_ids and self.codex and hasattr(self.codex, 'cospan_job_owners'):
            job_owners = self.codex.cospan_job_owners(target_job_ids, active_ids=set(entries), history_ids=set(history))

        # Group active cospan child tasks under their parent task.
        active_subtasks = {}
        top_entries = {}
        for key, entry in entries.items():
            parent_id = _find_cospan_parent(key, entry, entries, cospan_jobs, job_owners, updated)
            if parent_id:
                sub = {k: v for k, v in entry.items() if k in fields}
                sub['title'] = _cospan_subtask_title(entry, cospan_jobs.get(key))
                active_subtasks.setdefault(parent_id, []).append(sub)
                continue
            # Avoid leaving an already-completed cospan subtask orphaned at top-level
            # when its parent task is not active (dismissed, archived, or unavailable).
            if entry.get('status') == 'completed' and _is_cospan_entry(key, entry, cospan_jobs):
                continue
            top_entries[key] = entry

        tasks = []
        for key, entry in top_entries.items():
            item = {k: v for k, v in entry.items() if k in fields}
            subs = active_subtasks.get(key)
            if subs:
                item['subtasks'] = sorted(subs, key=lambda v: (priority[v['status']], v.get('source', ''), v['title']))
            tasks.append(item)
        tasks.sort(key=lambda v: (priority[v['status']], v.get('source', ''), v['title']))

        # Group history cospan child tasks under their parent task as well.
        history_subtasks = {}
        top_history = {}
        for key, entry in history.items():
            parent_id = _find_cospan_parent(key, entry, history, cospan_jobs, job_owners, updated)
            if parent_id:
                sub = dict({k: v for k, v in entry.items() if k in fields}, updated=updated(entry))
                sub['title'] = _cospan_subtask_title(entry, cospan_jobs.get(key))
                history_subtasks.setdefault(parent_id, []).append(sub)
                continue
            top_history[key] = entry

        self.history = []
        for entry in sorted(top_history.values(), key=lambda entry: (-updated(entry), entry['id'])):
            item = dict({k: v for k, v in entry.items() if k in fields}, updated=updated(entry))
            subs = history_subtasks.get(entry['id'])
            if subs:
                item['subtasks'] = sorted(subs, key=lambda v: (-v.get('updated', 0), v['id']))
            self.history.append(item)
        self.entries = entries
        self.source_errors = errors
        health = []
        for key, (name, _, mode) in PRODUCTS.items():
            observed = key in hooks_seen or any(v.get('provider') == key for v in self.native.values())
            configured = installed_hooks.get(key, {})
            is_disabled = key in disabled_providers
            state = '读取异常' if key in errors else ('已屏蔽' if is_disabled else ('已收到任务' if observed else ('已配置，等待新任务' if configured.get('installed') else ('已安装，待接入' if self.installed.get(key) else '未检测到客户端'))))
            if configured.get('error') and not observed and not is_disabled:
                state = '接入配置异常'
            if key == 'codex' and self.codex and self.codex.database.exists() and key not in errors and not is_disabled:
                state = '已连接'
            detail = ''
            if key == 'qianwen':
                detail = '读取千问「工作」模式写入本机的任务记录。'
                if key not in errors and not observed and not is_disabled:
                    if next(qianwen_session_indexes(self.home), None):
                        state = '已连接'
                    elif self.installed.get(key):
                        state = '已安装，等待本地工作任务'
            if key == 'claude':
                detail = 'Claude 桌面的 Code 本地会话和 Claude Code CLI 使用相同的事件配置。'
            health.append(dict(id=key, name=name, mode=mode, state=state,
                               disabled=is_disabled,
                               installed=bool(self.installed.get(key)), apps=self.installed.get(key, []),
                               error=errors.get(key, ''), setup_error=configured.get('error', ''), detail=detail))
        snapshot = dict(tasks=tasks, history=self.history, sources=health, error='', updated=time.time())
        encoded = json.dumps([tasks, self.history, health], ensure_ascii=False, sort_keys=True)
        if encoded != self.last_output:
            atomic_json(self.data / 'session.json', entries)
            atomic_json(self.data / 'snapshot.json', snapshot)
            self.last_output = encoded
        else:
            os.utime(self.data / 'snapshot.json', None)
