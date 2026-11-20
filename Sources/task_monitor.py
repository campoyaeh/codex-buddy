#!/usr/bin/env python3
"""Read Codex's local event journal and publish an atomic floating-panel snapshot."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import time

HOME = Path.home() / '.codex'
DATA = Path(os.environ.get('TASK_PANEL_DATA_DIR', str(HOME / 'task-manager')))
TERMINAL = {'task_complete', 'turn_aborted'}


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False))
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def plain(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(x.get('text', '') for x in content if isinstance(x, dict))
    return ''


def apply_record(task, record):
    payload = record.get('payload', {})
    kind = payload.get('type')
    if record.get('type') == 'event_msg':
        if kind == 'task_started':
            turn = payload.get('turn_id', '')
            if task.get('turn') != turn:
                task.update(turn=turn, status='running', detail='正在处理任务', pending={}, activity=record.get('timestamp', ''))
        elif kind in TERMINAL:
            if payload.get('turn_id') and task.get('turn') and payload['turn_id'] != task['turn']:
                return
            if kind == 'turn_aborted':
                task['pending'] = {}
            task['status'] = 'waiting' if task.get('pending') else ('completed' if kind == 'task_complete' else 'stopped')
            task['detail'] = ('\n'.join(p['question'] for p in task['pending'].values()) if task.get('pending') else plain(payload.get('last_agent_message'))) or ('任务已停止' if kind == 'turn_aborted' else '处理完成，等待确认')
            task['activity'] = record.get('timestamp', '')
        elif kind == 'user_message':
            task['pending'] = {}
            task['status'] = 'running'
        return
    if record.get('type') != 'response_item':
        return
    if kind == 'message' and payload.get('role') == 'user':
        task['pending'] = {}
        task['status'] = 'running'
    if kind == 'message' and payload.get('role') == 'assistant' and task.get('status') == 'running':
        text = plain(payload.get('content'))
        if text:
            task['detail'] = text
    name = payload.get('name', '').split('.')[-1]
    if kind == 'function_call' and name in {'request_user_input', 'request_user_input_async'}:
        arguments = payload.get('arguments', '{}')
        try:
            args = json.loads(arguments) if isinstance(arguments, str) else arguments
        except ValueError:
            args = {}
        questions = args.get('questions', [])
        question = '\n'.join(q.get('question', q.get('title', '')) for q in questions if isinstance(q, dict))
        task.setdefault('pending', {})[payload.get('call_id', '')] = {'async': name.endswith('_async'), 'question': question}
        task['status'] = 'waiting'
        task['detail'] = question or '需要你的输入，请打开聊天处理'
    if kind == 'function_call_output':
        call = payload.get('call_id', '')
        pending = task.get('pending', {})
        # Async tool acknowledgement is delivered before the user responds.
        if call in pending and not pending[call]['async']:
            del pending[call]
            if not pending:
                task.update(status='running', detail='已收到输入，继续处理')


def relevant_line(line):
    # Journal tool output and token records can be very large.
    return any(marker in line for marker in (
        b'"type": "task_started"', b'"type":"task_started"',
        b'"type": "task_complete"', b'"type":"task_complete"',
        b'"type": "turn_aborted"', b'"type":"turn_aborted"',
        b'"type": "user_message"', b'"type":"user_message"',
        b'"type": "message"', b'"type":"message"',
        b'"type": "function_call"', b'"type":"function_call"',
        b'"type": "function_call_output"', b'"type":"function_call_output"',
    ))


def initial_records(path):
    """Walk backwards to the latest turn boundary, without a fixed tail limit."""
    size = path.stat().st_size
    with path.open('rb') as handle:
        position = size
        suffix = b''
        records = []
        handle.seek(max(0, size - 262144))
        tail = handle.read()
        complete_size = size if tail.endswith(b'\n') else size - len(tail.rsplit(b'\n', 1)[-1])
        position = complete_size
        while position:
            start = max(0, position - 262144)
            handle.seek(start)
            block = handle.read(position - start) + suffix
            lines = block.split(b'\n')
            suffix = lines.pop(0) if start else b''
            for line in reversed(lines):
                if not relevant_line(line):
                    continue
                try:
                    item = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                records.append(item)
                payload = item.get('payload', {})
                if item.get('type') == 'event_msg' and payload.get('type') == 'task_started':
                    return reversed(records), complete_size
            position = start
        return reversed(records), complete_size


class Monitor:
    def __init__(self, data=DATA, database=HOME / 'state_5.sqlite'):
        self.data = data
        data.mkdir(parents=True, exist_ok=True)
        self.database = database
        self.entries = {}
        self.history = []
        self.cache = {}
        self.states = {}
        self.dismissed = read_json(data / 'dismissed.json', {})
        self.last_output = None
        self._db_sig = None
        self._rows_cache = []
        self._receipts_cache = {}
        self._has_receipts = False
        self._dismissed_sig = None
        self._ordered_cache = []
        self.changed = True

    @staticmethod
    def _file_sig(path):
        try:
            st = path.stat()
            return (st.st_ino, st.st_size, st.st_mtime_ns)
        except OSError:
            return None

    def tick(self, publish=True):
        dismissed_sig = self._file_sig(self.data / 'dismissed.json')
        dismissed_changed = dismissed_sig != self._dismissed_sig
        if dismissed_changed:
            self.dismissed = read_json(self.data / 'dismissed.json', self.dismissed)
            self._dismissed_sig = dismissed_sig
        wal_path = self.database.with_name(self.database.name + '-wal')
        db_sig = (self._file_sig(self.database), self._file_sig(wal_path))
        db_changed = db_sig != self._db_sig or self._db_sig is None
        if db_changed:
            with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True, timeout=2) as connection:
                has_receipts = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='thread_read_receipts'").fetchone()
                receipts = dict(connection.execute('SELECT thread_id, first_unread_turn FROM thread_read_receipts')) if has_receipts else {}
                columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
                updated = 'updated_at * 1000' if 'updated_at' in columns else '0'
                if 'updated_at_ms' in columns:
                    updated = f'COALESCE(updated_at_ms, {updated})'
                filters = [
                    "archived=0",
                    "thread_source IN ('user','automation','agent_created_thread')",
                    "attached_thread_parent_id IS NULL",
                ]
                if 'source' in columns:
                    filters.append("(source IS NULL OR source NOT LIKE '{\"subagent\"%')")
                if 'agent_path' in columns:
                    filters.append("(agent_path IS NULL OR agent_path = '')")
                rows = connection.execute(
                    f"SELECT {updated}, id, COALESCE(NULLIF(name,''),title), cwd, rollout_path "
                    f"FROM threads WHERE {' AND '.join(filters)}"
                ).fetchall()
            self._db_sig = db_sig
            self._rows_cache = rows
            self._receipts_cache = receipts
            self._has_receipts = bool(has_receipts)
        else:
            rows = self._rows_cache
            receipts = self._receipts_cache
            has_receipts = self._has_receipts
        journals_changed = False
        present = set()
        for updated, thread, title, cwd, filename in rows:
            present.add(thread)
            path = Path(filename)
            try:
                stat = path.stat()
            except OSError:
                continue
            signature = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
            previous = self.cache.get(thread)
            if previous and previous['signature'] == signature:
                if db_changed and thread in self.states:
                    self.states[thread].update(title=' '.join(title.split()), project=Path(cwd).name)
                continue
            journals_changed = True
            task = self.states.get(thread, {'id': thread, 'pending': {}}).copy()
            if previous and previous['inode'] == stat.st_ino and stat.st_size >= previous['offset']:
                with path.open('rb') as handle:
                    handle.seek(previous['offset'])
                    chunk = handle.read()
                boundary = chunk.rfind(b'\n') + 1
                records = []
                for line in chunk[:boundary].splitlines():
                    if not relevant_line(line):
                        continue
                    try:
                        records.append(json.loads(line))
                    except (ValueError, UnicodeDecodeError):
                        pass
                offset = previous['offset'] + boundary
            else:
                records, offset = initial_records(path)
                # Reconstruct the current turn after a service restart.
                task = {'id': thread, 'pending': {}}
            for record in records:
                apply_record(task, record)
            task.update(title=' '.join(title.split()), project=Path(cwd).name)
            self.cache[thread] = {'signature': signature, 'inode': stat.st_ino, 'offset': offset}
            self.states[thread] = task
        self.changed = db_changed or journals_changed or dismissed_changed
        if not self.changed and not publish:
            return self._ordered_cache
        if db_changed or journals_changed:
            self.history = [dict(id=thread, title=' '.join((title or 'Codex 对话').split()),
                                 project=Path(cwd or '').name, updated=(updated or 0) / 1000,
                                 turn='', status='stopped')
                            for updated, thread, title, cwd, filename in rows]
            self.states = {key: task for key, task in self.states.items() if key in present}
            for entry in self.history:
                state = self.states.get(entry['id'], {})
                entry.update(turn=state.get('turn', ''), status=state.get('status', 'stopped'))
        self.entries = {}
        for thread, task in self.states.items():
            status = task.get('status')
            turn = task.get('turn', '')
            suffix = ':completed' if status == 'completed' else (':running' if status == 'running' else '')
            dismissal_key = turn + suffix
            if status in {'running', 'waiting', 'completed'} and self.dismissed.get(thread) == dismissal_key:
                continue
            if status == 'completed':
                # Refresh receipts even when the journal is unchanged. Existing
                # history without an unread receipt must not flood the panel.
                if has_receipts and not receipts.get(thread):
                    continue
            elif status not in {'running', 'waiting'}:
                continue
            self.entries[thread] = task
        priority = {'waiting': 0, 'completed': 1, 'running': 2}
        ordered = sorted(self.entries.values(), key=lambda t: (priority.get(t['status'], 4), t['title']))
        self._ordered_cache = ordered
        if not publish:
            return ordered
        tasks = [{key: task.get(key, '') for key in ('id', 'turn', 'title', 'status')} for task in ordered]
        encoded = json.dumps(tasks, ensure_ascii=False, sort_keys=True)
        if encoded != self.last_output:
            atomic_json(self.data / 'session.json', self.entries)
            atomic_json(self.data / 'snapshot.json', {'tasks': tasks, 'updated': time.time(), 'error': ''})
            self.last_output = encoded
        else:
            # Heartbeat allows the panel to report an unavailable monitor.
            os.utime(self.data / 'snapshot.json', None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent', type=int)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    DATA.mkdir(parents=True, exist_ok=True)
    collector_lock = (DATA / 'collector.lock').open('w')
    try:
        fcntl.flock(collector_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    from providers import UnifiedMonitor
    monitor = UnifiedMonitor(DATA, codex=Monitor())
    while not args.parent or os.getppid() == args.parent:
        try:
            monitor.tick()
        except Exception as error:
            atomic_json(DATA / 'snapshot.json', {'tasks': list(monitor.entries.values()), 'history': monitor.history, 'error': str(error), 'updated': time.time()})
            monitor.last_output = None
        if args.once:
            break
        time.sleep(1)


if __name__ == '__main__':
    main()
