import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).parents[1] / 'Sources/task_monitor.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def event(kind, **values):
    return {'type': 'event_msg', 'payload': {'type': kind, 'turn_id': 'turn-1', **values}}


def question(async_call=True):
    return {'type': 'response_item', 'payload': {'type': 'function_call', 'call_id': 'question', 'name': 'request_user_input_async' if async_call else 'request_user_input', 'arguments': json.dumps({'questions': [{'title': '确认需求'}]})}}


class MonitorTests(unittest.TestCase):
    def test_async_ack_keeps_waiting(self):
        task = {}
        for record in [event('task_started'), question(), {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'question', 'output': '{"accepted":true}'}}]:
            m.apply_record(task, record)
        self.assertEqual(task['status'], 'waiting')
        m.apply_record(task, event('task_complete', last_agent_message='请回复'))
        self.assertEqual(task['status'], 'waiting')
        self.assertEqual(task['detail'], '确认需求')

    def test_sync_answer_and_user_reply(self):
        task = {}
        for record in [event('task_started'), question(False), {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'question'}}]:
            m.apply_record(task, record)
        self.assertEqual(task['status'], 'running')
        m.apply_record(task, question())
        m.apply_record(task, {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user'}})
        self.assertFalse(task['pending'])
        m.apply_record(task, event('task_complete', last_agent_message='已完成'))
        self.assertEqual(task['status'], 'completed')

    def test_abort_clears_pending_input(self):
        task = {}
        for record in [event('task_started'), question(), event('turn_aborted')]:
            m.apply_record(task, record)
        self.assertEqual(task['status'], 'stopped')
        self.assertFalse(task['pending'])

    def test_old_turn_completion_cannot_finish_new_turn(self):
        task = {}
        m.apply_record(task, event('task_started', turn_id='new-turn'))
        m.apply_record(task, event('task_complete'))
        self.assertEqual(task['status'], 'running')

    def test_stream_lifecycle_restart_and_partial_line(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            log = root / 'rollout.jsonl'
            def append(record, newline=True):
                with log.open('a') as handle:
                    handle.write(json.dumps(record) + ('\n' if newline else ''))
            append(event('task_started'))
            append(event('task_complete', last_agent_message='历史任务'))
            db = root / 'state.sqlite'
            with sqlite3.connect(db) as connection:
                connection.execute('CREATE TABLE threads (id,title,name,cwd,rollout_path,archived,thread_source,attached_thread_parent_id)')
                connection.execute('CREATE TABLE thread_read_receipts (thread_id PRIMARY KEY,first_unread_turn,last_published_turn)')
                connection.execute('INSERT INTO thread_read_receipts VALUES (?,?,?)', ('thread',None,'turn-1'))
                connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,0,?,NULL)', ('thread','测试任务','','/project',str(log),'user'))
            monitor = m.Monitor(root / 'data', db)
            monitor.tick()
            self.assertFalse(monitor.entries, 'Read completions must stay hidden at startup')
            self.assertEqual(monitor.history[0]['id'], 'thread', 'Read conversations remain available in history')
            with sqlite3.connect(db) as connection:
                connection.execute("UPDATE thread_read_receipts SET first_unread_turn='turn-1'")
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'completed', 'Receipt-only updates must restore unread results')
            append(event('task_started', turn_id='turn-2'))
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'running')
            self.assertEqual(set(m.read_json(root / 'data/snapshot.json', {})['tasks'][0]), {'id', 'turn', 'title', 'status'})
            m.atomic_json(root / 'data/dismissed.json', {'thread':'turn-2'})
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'running', 'Legacy navigation dismissals must keep running tasks visible')
            restarted = m.Monitor(root / 'data', db)
            restarted.tick()
            self.assertEqual(restarted.entries['thread']['status'], 'running', 'Running tasks must remain visible after restart')
            append(question())
            monitor.tick()
            self.assertNotIn('thread', monitor.entries, 'Opened waiting tasks must stay hidden')
            restarted = m.Monitor(root / 'data', db)
            restarted.tick()
            self.assertNotIn('thread', restarted.entries, 'Waiting dismissal must persist after restart')
            append({'type': 'response_item', 'payload': {'type': 'message', 'role': 'user'}})
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'running', 'Resumed execution must reappear after waiting dismissal')
            append(event('task_complete', turn_id='turn-2', last_agent_message='完成'))
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'completed', 'Opening a running task must not hide its unread completion')
            m.atomic_json(root / 'data/dismissed.json', {'thread':'turn-2:completed'})
            monitor.tick()
            self.assertFalse(monitor.entries, 'Opening a completed result must hide it')
            restarted = m.Monitor(root / 'data', db)
            restarted.tick()
            self.assertFalse(restarted.entries, 'Completed dismissal must persist across restarts')
            append(event('task_started', turn_id='turn-3'), False)
            monitor.tick()
            self.assertFalse(monitor.entries, 'Partial records must wait for newline')
            with log.open('a') as handle: handle.write('\n')
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['turn'], 'turn-3')
            append(event('task_complete', turn_id='turn-3', last_agent_message='处理完成'))
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'completed')
            monitor.tick()
            self.assertEqual(monitor.entries['thread']['status'], 'completed', 'Unread completion must remain without new events')
            restarted = m.Monitor(root / 'data', db)
            restarted.tick()
            self.assertEqual(restarted.entries['thread']['status'], 'completed', 'Unread completion must survive restart')
            with sqlite3.connect(db) as connection:
                connection.execute("UPDATE thread_read_receipts SET first_unread_turn=NULL,last_published_turn='turn-3'")
            restarted.tick()
            self.assertNotIn('thread', restarted.entries, 'Reading directly in Codex must remove the result without a journal change')
            with sqlite3.connect(db) as connection:
                connection.execute('DELETE FROM thread_read_receipts')
            restarted.tick()
            self.assertNotIn('thread', restarted.entries, 'History without unread receipts must stay hidden')

    def test_history_uses_database_updates_even_without_journals(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            db = root / 'state.sqlite'
            with sqlite3.connect(db) as connection:
                connection.execute('CREATE TABLE threads (id,title,name,cwd,rollout_path,archived,thread_source,attached_thread_parent_id,updated_at,updated_at_ms)')
                for index in range(12):
                    connection.execute('INSERT INTO threads VALUES (?,?,?,?,?,0,?,NULL,?,?)',
                                       (str(index), f'对话 {index}', '', '/project', str(root / 'missing'), 'user', 1000 + index, None))
            monitor = m.Monitor(root / 'data', db)
            monitor.tick(publish=False)
            self.assertFalse(monitor.entries)
            self.assertEqual(len(monitor.history), 12)
            self.assertEqual(max(monitor.history, key=lambda entry: entry['updated'])['id'], '11')
            with sqlite3.connect(db) as connection:
                connection.execute("UPDATE threads SET updated_at_ms=2000000 WHERE id='0'")
            monitor.tick(publish=False)
            self.assertEqual(max(monitor.history, key=lambda entry: entry['updated'])['id'], '0')

    def test_large_turn_is_found_beyond_tail(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'log.jsonl'
            records = [event('task_started'), question(), {'type':'ignored','payload': {'text':'x'*700000}}]
            path.write_text(''.join(json.dumps(record)+'\n' for record in records))
            recovered, _ = m.initial_records(path)
            task = {}
            for record in recovered: m.apply_record(task, record)
            self.assertEqual(task['status'], 'waiting')


if __name__ == '__main__':
    unittest.main()
