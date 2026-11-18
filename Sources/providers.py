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


def set_antigravity_navigation_targets(home, history):
    tasks = [entry for entry in history.values() if entry.get('provider') == 'antigravity']
    path = home / '.gemini/antigravity/conversation_summaries.db'
    if not tasks or not path.is_file():
        return
    query = ("SELECT conversation_id, parent_conversation_id FROM conversation_summaries "
             "WHERE parent_conversation_id <> ''")
    try:
        with closing(database(path)) as connection:
            parents = dict(connection.execute(query))
    except sqlite3.Error:
        # SQLite can refuse a read-only open of an idle WAL-mode database
        # whose client removed the sidecars. Never ignore an existing WAL.
        wal = path.with_name(path.name + '-wal')
        if wal.exists():
            return
        try:
            before = path.stat()
            with closing(sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
                parents = dict(connection.execute(query))
            if wal.exists() or path.stat().st_mtime_ns != before.st_mtime_ns:
                return
        except (OSError, sqlite3.Error):
            return
    for entry in tasks:
        target = entry.get('session')
        visited = {target}
        while target in parents and parents[target] not in visited:
            target = parents[target]
            visited.add(target)
        if target not in parents and target != entry.get('session'):
            entry['navigation_id'] = 'antigravity:' + target


def deepseek_tasks(home):
    root = home / '.dsh/storages/session_projcache/sessions'
    result = []
    for path in root.glob('session-*.json'):
        record = read_json(path, {}).get('record', {})
        rows = record.get('rows', {})
        def value(key, default=None):
            return rows.get(key, {}).get('val', default)
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
                if data.get('deletedAt') is not None:
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
                    or record.get('projectId') != project or record.get('archived') or record.get('sessionType') == 'voice'):
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

    def discover(self):
        if time.time() - self.last_discovery < 30:
            return
        self.last_discovery = time.time()
        roots = [Path('/Applications'), self.home / 'Applications']
        self.installed = {key: [str(root / (name + '.app')) for root in roots for name in names if (root / (name + '.app')).exists()]
                          for key, (_, names, _) in PRODUCTS.items()}

    def tick(self):
        self.discover()
        entries, errors = {}, {}
        history = {}
        dismissed = read_json(self.data / 'dismissed.json', {})
        if self.codex and self.codex.database.exists():
            try:
                codex_tasks = self.codex.tick(publish=False)
                for entry in self.codex.history:
                    history[entry['id']] = dict(entry, provider='codex', source='Codex', navigation='session',
                                                open_url='codex://threads/' + quote(entry['id'], safe=''))
                for entry in codex_tasks:
                    entry = dict(entry, provider='codex', source='Codex', navigation='session',
                                 open_url='codex://threads/' + quote(entry['id'], safe=''))
                    entries[entry['id']] = entry
            except (OSError, sqlite3.Error, ValueError) as error:
                errors['codex'] = str(error)
                entries.update({k: dict(v, stale=True) for k, v in self.entries.items() if v.get('provider') == 'codex'})
        dirty = False
        native_present = set()
        for provider, collect in NATIVE.items():
            try:
                for current in collect(self.home):
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
            except (OSError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
                errors[provider] = str(error)
                entries.update({k: dict(v, stale=True) for k, v in self.entries.items() if v.get('provider') == provider})
        # Removed sessions are no longer candidates. Keep failed sources intact.
        for key in list(self.native):
            if key not in native_present and self.native[key]['provider'] not in errors:
                del self.native[key]
                dirty = True
        if dirty:
            atomic_json(self.data / 'native-state.json', self.native)
        hooks_seen = set()
        for path in (self.data / 'events').glob('*.json'):
            entry = read_json(path)
            if not isinstance(entry, dict) or entry.get('provider') not in PRODUCTS:
                continue
            history[entry['id']] = entry
            if time.time() - entry.get('updated', 0) > 86400 and entry.get('status') in ('running', 'waiting'):
                continue  # A vanished client must not look busy forever.
            hooks_seen.add(entry['provider'])
            if entry.get('status') in ('running', 'waiting', 'completed'):
                # Event hooks have higher fidelity than local history.
                entries[entry['id']] = entry
            else:
                entries.pop(entry['id'], None)
        set_antigravity_navigation_targets(self.home, history)
        for key, entry in history.items():
            if entry.get('navigation') == 'application' and self.installed.get(entry.get('provider')):
                entry['app'] = Path(self.installed[entry['provider']][0]).stem
        for key, entry in list(entries.items()):
            if entry.get('navigation') == 'application' and self.installed.get(entry.get('provider')):
                candidates = self.installed[entry['provider']]
                if not any(Path(candidate).stem == entry.get('app') for candidate in candidates):
                    entry['app'] = Path(candidates[0]).stem
            dismissal = entry['turn'] + (':completed' if entry['status'] == 'completed' else '')
            if entry['status'] != 'running' and dismissed.get(key) == dismissal:
                del entries[key]
        priority = {'waiting': 0, 'completed': 1, 'running': 2}
        fields = {'id', 'turn', 'title', 'status', 'provider', 'source', 'navigation', 'navigation_id', 'open_url',
                  'app', 'bundle_id', 'resume_command', 'waiting_kind', 'stale', 'project'}
        tasks = sorted([{k: v for k, v in entry.items() if k in fields} for entry in entries.values()],
                       key=lambda v: (priority[v['status']], v.get('source', ''), v['title']))
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
        self.history = [dict({k: v for k, v in entry.items() if k in fields}, updated=updated(entry))
                        for entry in sorted(history.values(), key=lambda entry: (-updated(entry), entry['id']))]
        self.entries = entries
        installed_hooks = read_json(self.data / 'integrations.json', {})
        health = []
        for key, (name, _, mode) in PRODUCTS.items():
            observed = key in hooks_seen or any(v.get('provider') == key for v in self.native.values())
            configured = installed_hooks.get(key, {})
            state = '读取异常' if key in errors else ('已收到任务' if observed else ('已配置，等待新任务' if configured.get('installed') else ('已安装，待接入' if self.installed.get(key) else '未检测到客户端')))
            if configured.get('error') and not observed:
                state = '接入配置异常'
            if key == 'codex' and self.codex and self.codex.database.exists() and key not in errors:
                state = '已连接'
            detail = ''
            if key == 'qianwen':
                detail = '读取千问「工作」模式写入本机的任务记录。'
                if key not in errors and not observed:
                    if next(qianwen_session_indexes(self.home), None):
                        state = '已连接'
                    elif self.installed.get(key):
                        state = '已安装，等待本地工作任务'
            if key == 'claude':
                detail = 'Claude 桌面的 Code 本地会话和 Claude Code CLI 使用相同的事件配置。'
            health.append(dict(id=key, name=name, mode=mode, state=state,
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
