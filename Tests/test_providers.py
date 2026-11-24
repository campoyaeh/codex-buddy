import json
import shutil
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'Sources'))
import providers as p
import task_bridge as bridge
import integrations as setup


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.data = Path(self.temp.name) / 'panel'
        self.home.mkdir()

    def receive(self, provider='claude', event='UserPromptSubmit', **payload):
        return bridge.receive(provider, event, dict(session_id='same-session', **payload), self.data)

    def monitor(self):
        monitor = p.UnifiedMonitor(self.data, home=self.home)
        monitor.tick()
        return monitor

    def qianwen_fixture(self, **metadata):
        sessions = self.home / 'Library/Application Support/Qianwen/qwen-agent/account/projects/project/sessions'
        p.atomic_json(sessions / 'sessions.json', dict(schemaVersion=1, threads=[
            dict(id='thread', projectId='project', title='千问测试', **metadata),
        ]))
        journal = sessions / 'thread/thread-events.jsonl'
        journal.parent.mkdir()
        return journal

    def qianwen_event(self, journal, kind, turn='turn-1', **payload):
        scope = payload.pop('scope', 'main')
        timestamp = payload.pop('timestamp', '2026-11-18T08:00:00.000Z')
        row = dict(schemaVersion=2, threadId='thread', turnId=turn, timestamp=timestamp,
                   type=kind, scope=scope, payload=payload)
        with journal.open('a') as handle:
            handle.write(json.dumps(row) + '\n')

    @patch.object(p, 'qianwen_process_start', return_value=0)
    def test_qianwen_tracks_questions_and_only_completes_current_turn(self, process):
        journal = self.qianwen_fixture()
        self.qianwen_event(journal, 'turn_started')
        monitor = self.monitor()
        key = 'qianwen:account:project:thread'
        entry = monitor.entries[key]
        self.assertEqual(entry['status'], 'running')
        self.assertEqual(entry['bundle_id'], 'com.alibaba.tongyi')
        self.assertEqual(entry['open_url'], 'https://www.qianwen.com/chat/workbench?taskid=thread&projectid=project')
        self.qianwen_event(journal, 'canonical_item', scope='task',
                           item=dict(kind='tool-call', callId='subagent', toolName='AskUserQuestion'))
        self.qianwen_event(journal, 'turn_completed', turn='old-turn', status='completed')
        monitor.tick()
        self.assertEqual(monitor.entries[key]['status'], 'running')
        for call in ('first', 'second'):
            self.qianwen_event(journal, 'canonical_item', item=dict(kind='tool-call', callId=call, toolName='AskUserQuestion'))
        self.qianwen_event(journal, 'canonical_item', item=dict(kind='tool-output', callId='first'))
        monitor.tick()
        self.assertEqual(monitor.entries[key]['status'], 'waiting')
        self.qianwen_event(journal, 'canonical_item', item=dict(kind='tool-output', callId='second'))
        monitor.tick()
        self.assertEqual(monitor.entries[key]['status'], 'running')
        self.qianwen_event(journal, 'turn_completed', status='completed', assistantText='private reply')
        monitor.tick()
        self.assertEqual(monitor.entries[key]['status'], 'completed')
        self.assertNotIn('private reply', (self.data / 'snapshot.json').read_text())
        p.atomic_json(self.data / 'dismissed.json', {key: 'turn-1:completed'})
        self.assertNotIn(key, self.monitor().entries)

    @patch.object(p, 'qianwen_process_start', return_value=float('inf'))
    def test_qianwen_ignores_truncated_rows_and_never_celebrates_stops(self, process):
        journal = self.qianwen_fixture()
        self.qianwen_event(journal, 'turn_started')
        with journal.open('ab') as handle:
            handle.write(b'{"type":"turn_completed","ignored":"' + b'a' * 70000)
        self.assertEqual(p.qianwen_tasks(self.home)[0]['status'], 'stopped')
        with journal.open('rb+') as handle:
            handle.truncate(len(handle.readline()))
        monitor = self.monitor()
        self.qianwen_event(journal, 'turn_completed', status='aborted_streaming')
        monitor.tick()
        self.assertFalse(monitor.entries)
        self.assertEqual(monitor.history[0]['status'], 'stopped')

    def test_qianwen_fast_new_completion_and_historical_baseline(self):
        journal = self.qianwen_fixture()
        self.qianwen_event(journal, 'turn_started')
        self.qianwen_event(journal, 'turn_completed', status='completed')
        monitor = self.monitor()
        self.assertFalse(monitor.entries)
        self.assertEqual(monitor.history[0]['status'], 'completed')
        journal.unlink()
        monitor.tick()
        self.qianwen_event(journal, 'turn_started', turn='fast')
        self.qianwen_event(journal, 'turn_completed', turn='fast', status='completed', timestamp='2100-01-01T00:00:00Z')
        monitor.tick()
        self.assertEqual(monitor.entries['qianwen:account:project:thread']['turn'], 'fast')

    def test_parallel_clients_do_not_collide_and_questions_resume(self):
        for provider in ('claude', 'qwencode', 'copilot', 'kimi'):
            self.receive(provider, prompt='修复分页')
        monitor = self.monitor()
        self.assertEqual(len(monitor.entries), 4)
        first = self.receive(event='PermissionRequest')
        self.assertEqual(first['status'], 'waiting')
        self.assertEqual(self.receive(event='PostToolUse')['turn'], first['turn'])
        finished = self.receive(event='Stop')
        self.assertEqual(finished['status'], 'completed')
        p.atomic_json(self.data / 'dismissed.json', {'claude:same-session': finished['turn'] + ':completed'})
        monitor.tick()
        self.assertNotIn('claude:same-session', monitor.entries)
        next_turn = self.receive(prompt='再修复筛选')
        self.assertNotEqual(next_turn['turn'], finished['turn'])
        monitor.tick()
        self.assertEqual(monitor.entries['claude:same-session']['status'], 'running')

    def test_explicit_turn_rejects_old_completion_and_subagent(self):
        self.receive(turn_id='new')
        self.assertIsNone(self.receive(event='Stop', turn_id='old'))
        self.assertIsNone(self.receive(event='SubagentStop', turn_id='new'))
        self.assertEqual(self.monitor().entries['claude:same-session']['status'], 'running')

    def test_normal_cli_exit_preserves_unread_completion(self):
        self.receive()
        self.receive(event='Stop')
        ended = self.receive(event='SessionEnd', reason='complete')
        self.assertEqual(ended['status'], 'completed')

    def test_structured_question_and_stop_keep_waiting(self):
        self.receive()
        self.receive(event='PreToolUse', tool_name='AskUserQuestion')
        self.assertEqual(self.receive(event='Stop')['status'], 'waiting')
        self.assertEqual(self.receive(event='PostToolUse', tool_name='AskUserQuestion')['status'], 'running')

    def test_claude_question_survives_unrelated_parallel_tool_and_resume(self):
        first = self.receive(prompt='帮我确认方案')
        self.receive(event='PreToolUse', tool_name='AskUserQuestion', tool_use_id='question')
        self.assertEqual(self.receive(event='PostToolUse', tool_name='Read', tool_use_id='read')['status'], 'waiting')
        answered = self.receive(event='PostToolUse', tool_name='AskUserQuestion', tool_use_id='question')
        self.assertEqual(answered['status'], 'running')
        self.assertEqual(answered['turn'], first['turn'])
        self.receive(event='PermissionRequest', tool_name='Bash', tool_input={'command': 'pwd'})
        self.assertEqual(self.receive(event='PostToolUse', tool_name='Read', tool_use_id='other')['status'], 'waiting')
        resumed = self.receive(event='PostToolUse', tool_name='Bash', tool_use_id='bash', tool_input={'command': 'pwd'})
        self.assertEqual(resumed['status'], 'running')

    def test_claude_multiple_mcp_questions_resolve_independently(self):
        self.receive()
        self.receive(event='Elicitation', elicitation_id='one')
        self.receive(event='Elicitation', elicitation_id='two')
        self.assertEqual(self.receive(event='ElicitationResult', elicitation_id='one')['status'], 'waiting')
        self.assertEqual(self.receive(event='ElicitationResult', elicitation_id='two')['status'], 'running')

    def test_claude_tool_error_resumes_but_interrupt_and_api_error_stop(self):
        self.receive()
        self.receive(event='PermissionRequest', tool_name='Bash')
        self.assertEqual(self.receive(event='PostToolUseFailure', tool_name='Bash', error='failed')['status'], 'running')
        self.assertEqual(self.receive(event='PostToolUseFailure', is_interrupt=True)['status'], 'stopped')
        self.assertFalse(self.monitor().entries)
        self.receive()
        self.assertEqual(self.receive(event='StopFailure', error='rate_limit')['status'], 'stopped')
        self.assertFalse(self.monitor().entries)

    def test_claude_child_agent_cannot_clear_parent_question(self):
        self.receive()
        self.receive(event='PreToolUse', tool_name='AskUserQuestion', tool_use_id='one')
        for event in ('PreToolUse', 'PostToolUse', 'StopFailure', 'Stop'):
            self.assertIsNone(self.receive(event=event, agent_id='child'))
        self.assertEqual(self.monitor().entries['claude:same-session']['status'], 'waiting')

    def test_claude_reply_after_dismissed_question_starts_visible_turn(self):
        self.receive()
        waiting = self.receive(event='PreToolUse', tool_name='AskUserQuestion')
        p.atomic_json(self.data / 'dismissed.json', {'claude:same-session': waiting['turn']})
        self.assertFalse(self.monitor().entries)
        reply = self.receive(prompt='用第二个方案')
        self.assertNotEqual(reply['turn'], waiting['turn'])
        self.assertEqual(reply['pending'], {})
        self.assertEqual(self.monitor().entries['claude:same-session']['status'], 'running')

    def test_claude_installed_hook_commands_run_silently_end_to_end(self):
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'])
        config = json.loads((self.home / '.claude/settings.json').read_text())
        for event, payload, expected in [
            ('UserPromptSubmit', {'prompt': 'Claude 接入验证'}, 'running'),
            ('PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_use_id': 'q'}, 'waiting'),
            ('PostToolUse', {'tool_name': 'AskUserQuestion', 'tool_use_id': 'q'}, 'running'),
            ('Stop', {}, 'completed'),
            ('SessionEnd', {'reason': 'prompt_input_exit'}, 'completed'),
        ]:
            command = config['hooks'][event][-1]['hooks'][0]['command']
            result = subprocess.run(command, shell=True, input=json.dumps(dict(session_id='hook-session', **payload)), text=True, capture_output=True, timeout=5)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
            self.assertEqual(self.monitor().entries['claude:hook-session']['status'], expected)

    def test_claude_health_reflects_code_event_setup(self):
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'])
        monitor = p.UnifiedMonitor(self.data, home=self.home)
        with patch.object(monitor, 'discover'):
            monitor.installed = {'claude': ['/Applications/Claude.app']}
            monitor.tick()
        health = next(s for s in p.read_json(self.data / 'snapshot.json')['sources'] if s['id'] == 'claude')
        self.assertEqual(health['state'], '已配置，等待新任务')
        self.assertEqual(health['mode'], '事件接入')

    def test_event_id_dedup_and_metadata_do_not_start_work(self):
        first = self.receive('opencode', 'UserPromptSubmit', event_id='one')
        second = self.receive('opencode', 'UserPromptSubmit', event_id='one')
        self.assertEqual(first['turn'], second['turn'])
        self.receive('opencode', 'Stop')
        renamed = self.receive('opencode', 'SessionMetadata', title='新标题')
        self.assertEqual(renamed['status'], 'completed')
        self.assertEqual(renamed['title'], '新标题')

    def test_missing_identity_and_irrelevant_notifications_are_ignored(self):
        self.assertIsNone(bridge.receive('claude', 'Stop', {'cwd': '/same/path'}, self.data))
        self.assertIsNone(self.receive(event='Notification', notification_type='auth_success'))
        self.assertFalse(self.monitor().entries)

    def test_legacy_window_records_are_ignored_while_cli_events_continue(self):
        self.receive('kimi', prompt='编写程序')
        desktop = p.task('kimi', 'desktop:one', 'round', '阅读文档', 'running', scope='window')
        p.atomic_json(self.data / 'desktop-observations.json', {'trusted': True, 'tasks': [desktop]})
        monitor = self.monitor()
        self.assertEqual(set(monitor.entries), {'kimi:same-session'})
        self.assertEqual([entry['id'] for entry in monitor.history], ['kimi:same-session'])

    def test_antigravity_background_work_does_not_complete_early(self):
        payload = {'conversationId': 'ag', 'lastUserInput': '开发页面'}
        started = bridge.receive('antigravity', 'PreInvocation', payload, self.data)
        repeated = bridge.receive('antigravity', 'PreInvocation', dict(payload, invocationNum=2), self.data)
        self.assertEqual(started['turn'], repeated['turn'])
        partial = bridge.receive('antigravity', 'Stop', dict(payload, fullyIdle=False), self.data)
        self.assertEqual(partial['status'], 'running')
        done = bridge.receive('antigravity', 'Stop', dict(payload, fullyIdle=True), self.data)
        self.assertEqual(done['status'], 'completed')
        self.assertEqual(done['turn'], started['turn'])

    def test_antigravity_nested_subagent_tasks_are_hidden_from_lists(self):
        database = self.home / '.gemini/antigravity/conversation_summaries.db'
        database.parent.mkdir(parents=True)
        root = 'd1234567-89ab-cdef-0123-456789abcdff'
        child = '01234567-89ab-cdef-0123-456789abcdff'
        grandchild = '11234567-89ab-cdef-0123-456789abcdff'
        depth_only = '31234567-89ab-cdef-0123-456789abcdff'
        loop = '21234567-89ab-cdef-0123-456789abcdff'
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE conversation_summaries (conversation_id TEXT, parent_conversation_id TEXT, nesting_depth INTEGER)")
            connection.executemany(
                "INSERT INTO conversation_summaries VALUES (?,?,?)",
                [(root, '', 0), (child, root, 1), (grandchild, child, 2), (depth_only, '', 1), (loop, loop, 0)],
            )
        parent = bridge.receive('antigravity', 'PreInvocation', {'conversationId': root}, self.data)
        child_task = bridge.receive('antigravity', 'PreInvocation', {'conversationId': child}, self.data)
        reminder = bridge.receive('antigravity', 'Stop', {'conversationId': grandchild, 'fullyIdle': True}, self.data)
        depth_task = bridge.receive('antigravity', 'PreInvocation', {'conversationId': depth_only}, self.data)
        loop_reminder = bridge.receive('antigravity', 'Stop', {'conversationId': loop, 'fullyIdle': True}, self.data)
        monitor = self.monitor()
        self.assertEqual(set(monitor.entries), {parent['id'], loop_reminder['id']})
        self.assertNotIn(child_task['id'], monitor.entries)
        self.assertNotIn(reminder['id'], monitor.entries)
        self.assertNotIn(depth_task['id'], monitor.entries)
        snapshot = p.read_json(self.data / 'snapshot.json')
        for section in ('tasks', 'history'):
            ids = {row['id'] for row in snapshot[section]}
            self.assertIn(parent['id'], ids)
            self.assertNotIn(child_task['id'], ids)
            self.assertNotIn(reminder['id'], ids)
            self.assertNotIn(depth_task['id'], ids)
        with patch.object(p, 'database', side_effect=sqlite3.OperationalError):
            monitor.tick()
            self.assertEqual(set(monitor.entries), {parent['id'], loop_reminder['id']})

    def test_bridge_filters_subagent_and_child_payloads(self):
        self.assertIsNone(bridge.receive('claude', 'SubagentStart', {'session_id': 's1'}, self.data))
        self.assertIsNone(bridge.receive('cursor', 'beforeSubmitPrompt', {'conversation_id': 'c1', 'isSubagent': True}, self.data))
        self.assertIsNone(bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'ag-child', 'parentConversationId': 'ag-root'}, self.data))
        self.assertIsNone(bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'ag-deep', 'nestingDepth': 1}, self.data))
        self.assertIsNone(bridge.receive('copilot', 'userPromptSubmitted', {'sessionId': 'cp-child', 'parentSessionId': 'cp-root'}, self.data))
        self.assertEqual(self.monitor().entries, {})

    def test_hook_failure_is_silent_and_does_not_block_client(self):
        script = Path(bridge.__file__)
        result = subprocess.run(['/usr/bin/python3', str(script), '--provider', 'claude', '--event', 'Stop', '--data-dir', str(self.data)], input='invalid-json', text=True, capture_output=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_config_merge_is_idempotent_and_preserves_user_hooks(self):
        original = {'permissions': {'allow': ['Read']}, 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'my-hook'}]}]}}
        for dialect in ('nested', 'cursor', 'copilot', 'windsurf', 'antigravity'):
            merged = setup.merge_config(original, dialect, 'claude', ['Stop'], '/a path/task_bridge.py', self.data)
            again = setup.merge_config(merged, dialect, 'claude', ['Stop'], '/a path/task_bridge.py', self.data)
            self.assertEqual(merged, again)
            self.assertEqual(merged['permissions'], original['permissions'])
            self.assertIn('my-hook', json.dumps(merged))
        self.assertEqual(len(original['hooks']['Stop']), 1)

    def test_install_backup_remove_preserves_user_configuration(self):
        path = self.home / '.claude/settings.json'
        path.parent.mkdir()
        original = {'model': 'keep', 'hooks': {'Stop': [{'hooks': [{'command': 'user-hook'}]}]}}
        path.write_text(json.dumps(original))
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'])
        self.assertTrue(list((self.data / 'backups').rglob('settings.json')))
        installed = json.loads(path.read_text())
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'])
        self.assertEqual(installed, json.loads(path.read_text()))
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'], remove=True)
        removed = json.loads(path.read_text())
        self.assertEqual(removed['model'], 'keep')
        self.assertEqual(removed['hooks']['Stop'], original['hooks']['Stop'])

    def test_shared_hook_group_preserves_user_command_on_upgrade_and_remove(self):
        ours = {'type': 'command', 'command': setup.hook_command(Path(bridge.__file__), 'claude', 'Stop', self.data)}
        user = {'type': 'command', 'command': 'my-existing-hook'}
        original = {'hooks': {'Stop': [{'matcher': '*', 'hooks': [ours, user]}]}}
        merged = setup.merge_config(original, 'nested', 'claude', setup.CLAUDE_EVENTS, Path(bridge.__file__), self.data)
        self.assertEqual(merged['hooks']['Stop'][0], {'matcher': '*', 'hooks': [user]})
        path = self.home / '.claude/settings.json'
        path.parent.mkdir()
        path.write_text(json.dumps(original))
        setup.install(self.home, self.data, Path(bridge.__file__), ['claude'], remove=True)
        self.assertEqual(json.loads(path.read_text())['hooks']['Stop'], [{'matcher': '*', 'hooks': [user]}])

    def test_invalid_config_is_not_replaced(self):
        path = self.home / '.qwen/settings.json'
        path.parent.mkdir()
        path.write_text('{broken')
        report = setup.install(self.home, self.data, Path(bridge.__file__), ['qwencode'])
        self.assertFalse(report['qwencode']['installed'])
        self.assertTrue(report['qwencode']['error'])
        self.assertEqual(path.read_text(), '{broken')

    def test_kimi_toml_merge_preserves_other_tables(self):
        before = '[mcp.servers.test]\ncommand="existing"\n'
        merged = setup.merge_toml(before, 'kimi', ['Stop'], Path(bridge.__file__), self.data)
        self.assertEqual(merged, setup.merge_toml(merged, 'kimi', ['Stop'], Path(bridge.__file__), self.data))
        self.assertIn(before.strip(), merged)
        self.assertEqual(merged.count('[[hooks]]'), 1)

    def test_history_keeps_read_sessions_sorted_and_refreshes_without_task_changes(self):
        for index in range(15):
            entry = bridge.receive('claude', 'UserPromptSubmit', dict(session_id=f'history-{index}', prompt=f'对话 {index}'), self.data)
            entry = bridge.receive('claude', 'Stop', dict(session_id=f'history-{index}'), self.data)
            entry['updated'] = 1700000000 + index
            path = next(path for path in (self.data / 'events').glob('*.json') if p.read_json(path)['id'] == entry['id'])
            p.atomic_json(path, entry)
        monitor = self.monitor()
        snapshot = p.read_json(self.data / 'snapshot.json')
        self.assertEqual(len(snapshot['history']), 15)
        self.assertEqual(snapshot['history'][0]['id'], 'claude:history-14')
        p.atomic_json(self.data / 'dismissed.json', {e['id']: e['turn'] + ':completed' for e in snapshot['history']})
        monitor.tick()
        self.assertFalse(monitor.entries)
        self.assertEqual(len(p.read_json(self.data / 'snapshot.json')['history']), 15)
        restarted = self.monitor()
        self.assertEqual(len(restarted.history), 15)
        path = next(path for path in (self.data / 'events').glob('*.json') if p.read_json(path)['id'] == 'claude:history-0')
        changed = p.read_json(path)
        changed['updated'] = 1800000000
        p.atomic_json(path, changed)
        restarted.tick()
        self.assertFalse(restarted.entries)
        self.assertEqual(p.read_json(self.data / 'snapshot.json')['history'][0]['id'], 'claude:history-0')

    def test_no_codex_installation_still_publishes_sources(self):
        snapshot = p.read_json(self.data / 'snapshot.json') if self.data.exists() else None
        self.monitor()
        snapshot = p.read_json(self.data / 'snapshot.json')
        self.assertEqual(len(snapshot['sources']), 16)
        self.assertEqual(snapshot['error'], '')

    def deepseek(self, turn, status):
        path = self.home / '.dsh/storages/session_projcache/sessions/session-one.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        rows = {'title': {'val': '真实格式任务'}, 'turnBoundary': {'val': {
            'lastTurn': turn, 'openTurnStartSeq': 10 if status == 'running' else None,
            'lastStepBoundary': {'kind': 'start' if status == 'running' else 'end'}}},
            'userQuestions': {'val': {'questions': {'active': ['question'] if status == 'waiting' else []}}}}
        path.write_text(json.dumps({'record': {'rows': rows}}))

    def test_native_baseline_restart_read_and_new_turn(self):
        self.deepseek(1, 'completed')
        monitor = self.monitor()
        self.assertFalse(monitor.entries, 'Historical completions must not flood a new install')
        self.deepseek(2, 'running')
        monitor.tick()
        self.assertEqual(monitor.entries['deepseek:session-one']['turn'], '2')
        self.deepseek(2, 'completed')
        monitor.tick()
        self.assertEqual(monitor.entries['deepseek:session-one']['turn'], '2')
        self.assertEqual(self.monitor().entries['deepseek:session-one']['status'], 'completed')
        p.atomic_json(self.data / 'dismissed.json', {'deepseek:session-one': '2:completed'})
        self.assertFalse(self.monitor().entries)
        self.deepseek(3, 'running')
        self.assertEqual(self.monitor().entries['deepseek:session-one']['status'], 'running')

    def test_source_failure_does_not_break_other_clients(self):
        self.receive('claude')
        with patch.dict(p.NATIVE, {'minimax': lambda home: (_ for _ in ()).throw(sqlite3.DatabaseError('schema changed'))}):
            monitor = self.monitor()
        self.assertIn('claude:same-session', monitor.entries)
        health = {s['id']: s for s in p.read_json(self.data / 'snapshot.json')['sources']}
        self.assertEqual(health['minimax']['state'], '读取异常')

    def test_minimax_uses_ingress_and_questionnaire_not_idle_heuristics(self):
        db = self.home / '.minimax/v2/sqlite/runtime-state.sqlite'
        db.parent.mkdir(parents=True)
        with sqlite3.connect(db) as c:
            c.execute('CREATE TABLE local_runtime_sessions (session_id,title,status,archived,visibility,parent_session_id,updated_at_ms)')
            c.execute('CREATE TABLE local_runtime_message_rows (id INTEGER PRIMARY KEY,session_id,turn_id,role,data_json)')
            c.execute('CREATE TABLE local_runtime_turn_ingress (turn_id,session_id,status,accepted_at_ms)')
            c.execute('CREATE TABLE questionnaire_requests (session_id,status,answered_at,dismissed_at)')
            c.execute("INSERT INTO local_runtime_sessions VALUES ('one','任务','started',0,'visible',NULL,1)")
            c.execute("INSERT INTO local_runtime_message_rows VALUES (1,'one','turn','user','{}')")
            c.execute("INSERT INTO local_runtime_turn_ingress VALUES ('turn','one','accepted',1)")
        self.assertEqual(p.minimax_tasks(self.home)[0]['status'], 'running')
        with sqlite3.connect(db) as c:
            c.execute("INSERT INTO questionnaire_requests VALUES ('one','pending',NULL,NULL)")
        self.assertEqual(p.minimax_tasks(self.home)[0]['status'], 'waiting')
        with sqlite3.connect(db) as c:
            c.execute('UPDATE questionnaire_requests SET answered_at=1')
            c.execute("UPDATE local_runtime_turn_ingress SET status='completed'")
        self.assertEqual(p.minimax_tasks(self.home)[0]['status'], 'completed')

    def test_codebuddy_completion_keeps_running_turn_identity(self):
        values = [p.task('codebuddy', 'one', 'start', '任务', 'running')]
        with patch.dict(p.NATIVE, {'codebuddy': lambda home: values}):
            monitor = self.monitor()
            values[:] = [p.task('codebuddy', 'one', 'changed', '任务', 'completed')]
            monitor.tick()
            monitor.tick()
            values[:] = [p.task('codebuddy', 'one', 'renamed', '任务改名', 'completed')]
            monitor.tick()
        self.assertEqual(monitor.entries['codebuddy:one']['turn'], 'start')

    def test_codebuddy_actual_working_status_and_deleted_sessions(self):
        db = self.home / 'Library/Application Support/CodeBuddy CN/codebuddy-sessions.vscdb'
        db.parent.mkdir(parents=True)
        with sqlite3.connect(db) as c:
            c.execute('CREATE TABLE ItemTable (key,value)')
            c.execute('INSERT INTO ItemTable VALUES (?,?)', ('session:one', json.dumps({'conversationId': 'one', 'status': 'Working', 'updatedAt': 1})))
            c.execute('INSERT INTO ItemTable VALUES (?,?)', ('session:deleted', json.dumps({'conversationId': 'deleted', 'status': 'Working', 'deletedAt': 2})))
        tasks = p.codebuddy_tasks(self.home)
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['status'], 'running')

    @unittest.skipUnless(shutil.which('node'), 'Node is used to verify the OpenCode plugin')
    def test_opencode_plugin_relays_v1_and_v2_events_to_real_bridge(self):
        setup.install(self.home, self.data, Path(bridge.__file__), ['opencode'])
        plugin = self.home / '.config/opencode/plugins/ai-task-monitor/index.js'
        script = '''
          const {default: plugin, translate} = await import(process.argv[1]);
          const hooks = await plugin.server();
          await hooks.event({event:{type:'session.execution.started',id:'one',data:{sessionID:'v2'}}});
          await hooks.event({event:{type:'permission.asked',data:{sessionID:'v2'}}});
          await hooks.event({event:{type:'permission.replied',data:{sessionID:'v2'}}});
          await hooks.event({event:{type:'session.execution.succeeded',id:'two',data:{sessionID:'v2'}}});
          await hooks.event({event:{type:'session.status',properties:{sessionID:'v1',status:{type:'busy'}}}});
          await hooks.event({event:{type:'session.idle',properties:{sessionID:'v1'}}});
          if(translate({type:'session.updated',properties:{info:{id:'child',parentID:'parent'}}})) throw Error('subagent leaked');
        '''
        completed = subprocess.run(['node', '--input-type=module', '-e', script, plugin.as_uri()], capture_output=True, text=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        monitor = self.monitor()
        self.assertEqual(set(monitor.entries), {'opencode:v1', 'opencode:v2'})
        self.assertTrue(all(t['status'] == 'completed' for t in monitor.entries.values()))

    def test_antigravity_uppercase_cancel_and_error_stop_cleanly(self):
        for reason in ('USER_CANCELED', 'ERROR', 'MAX_INVOCATIONS'):
            cid = 'ag-' + reason.lower()
            bridge.receive('antigravity', 'PreInvocation', {'conversationId': cid, 'lastUserInput': '测试'}, self.data)
            stopped = bridge.receive('antigravity', 'Stop', {'conversationId': cid, 'terminationReason': reason}, self.data)
            self.assertEqual(stopped['status'], 'stopped')
        monitor = self.monitor()
        self.assertEqual(monitor.entries, {})

    def test_antigravity_post_tool_use_uses_matcher_group(self):
        merged = setup.merge_config({}, 'antigravity', 'antigravity', ['PreInvocation', 'PostToolUse', 'Stop'], '/b/task_bridge.py', self.data)
        self.assertEqual(merged['ai-task-monitor']['PostToolUse'][0]['matcher'], '*')
        self.assertTrue(isinstance(merged['ai-task-monitor']['PostToolUse'][0]['hooks'], list))
        self.assertEqual(merged['ai-task-monitor']['PreInvocation'][0]['type'], 'command')
        self.assertEqual(merged, setup.merge_config(merged, 'antigravity', 'antigravity', ['PreInvocation', 'PostToolUse', 'Stop'], '/b/task_bridge.py', self.data))

    def test_antigravity_idle_or_killed_summary_reconciles_stuck_running_task(self):
        database = self.home / '.gemini/antigravity/conversation_summaries.db'
        database.parent.mkdir(parents=True)
        now = p.time.time()
        with sqlite3.connect(database) as connection:
            connection.execute(
                "CREATE TABLE conversation_summaries "
                "(conversation_id TEXT, parent_conversation_id TEXT, status TEXT, not_fully_idle INTEGER, killed INTEGER, last_modified_time TEXT)"
            )
            connection.executemany(
                "INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?)",
                [
                    ('stuck-idle', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '2026-11-19 03:56:54.94332+00:00'),
                    ('stuck-killed', '', 'CASCADE_RUN_STATUS_RUNNING', 1, 1, '2026-11-19 03:56:54+00:00'),
                    ('still-running', '', 'CASCADE_RUN_STATUS_RUNNING', 1, 0, '2026-11-19 03:56:54+00:00'),
                    ('just-started', '', 'CASCADE_RUN_STATUS_IDLE', 0, 0, '2020-01-01 00:00:00+00:00'),
                ],
            )
        bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'stuck-idle', 'lastUserInput': '出错暂停'}, self.data, now=now - 60)
        bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'stuck-killed', 'lastUserInput': '手动中止'}, self.data, now=now - 1)
        bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'still-running', 'lastUserInput': '仍在运行'}, self.data, now=now - 60)
        bridge.receive('antigravity', 'PreInvocation', {'conversationId': 'just-started', 'lastUserInput': '刚刚开始'}, self.data, now=now)
        monitor = self.monitor()
        self.assertEqual(set(monitor.entries), {'antigravity:still-running', 'antigravity:just-started'})

    def test_dismissing_running_task_hides_only_running_state_for_turn(self):
        started = bridge.receive('cursor', 'beforeSubmitPrompt', {'conversation_id': 'c1', 'prompt': '构建'}, self.data)
        p.atomic_json(self.data / 'dismissed.json', {started['id']: started['turn'] + ':running'})
        monitor = self.monitor()
        self.assertEqual(monitor.entries, {})
        bridge.receive('cursor', 'stop', {'conversation_id': 'c1'}, self.data)
        monitor.tick()
        self.assertIn(started['id'], monitor.entries)
        self.assertEqual(monitor.entries[started['id']]['status'], 'completed')

    def test_disabled_providers_are_filtered_and_restored(self):
        bridge.receive('cursor', 'beforeSubmitPrompt', {'conversation_id': 'c2', 'prompt': '分析日志'}, self.data)
        p.atomic_json(self.data / 'settings.json', {'disabledProviders': ['cursor']})
        monitor = self.monitor()
        self.assertEqual(monitor.entries, {})
        snap = p.read_json(self.data / 'snapshot.json')
        cursor_source = next(s for s in snap['sources'] if s['id'] == 'cursor')
        self.assertEqual(cursor_source['state'], '已屏蔽')
        self.assertTrue(cursor_source['disabled'])
        p.atomic_json(self.data / 'settings.json', {'disabledProviders': []})
        monitor.tick()
        self.assertIn('cursor:c2', monitor.entries)

    def test_cospan_subtasks_merge_into_codex_parent_and_reconcile_status(self):
        import task_monitor as tm
        codex_db = self.home / '.codex/state_5.sqlite'
        codex_db.parent.mkdir(parents=True, exist_ok=True)
        rollout_a = self.home / '.codex/rollout-a.jsonl'
        rollout_a.write_text(
            json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': 'turn-a'}}) + '\n'
            + json.dumps({'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'c1',
                                                               'output': 'started agy-261123150255-2745ae and dsh-261123150446-473b76 and agy-261123150500-deadbe'}}) + '\n'
        )
        with sqlite3.connect(codex_db) as con:
            con.execute(
                "CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, rollout_path TEXT, "
                "archived INTEGER, thread_source TEXT, attached_thread_parent_id TEXT, updated_at INTEGER)"
            )
            con.execute(
                "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)",
                ('codex-parent-a', '$prod-rd 研发主任务', '$prod-rd 研发主任务', '/tmp/SmartBiz',
                 str(rollout_a), 0, 'user', None, int(p.time.time())),
            )
        state_file = self.home / '.cospan/trajectories/SmartBiz-abc/state.json'
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps({
            'jobs': [
                {'id': 'agy-261123150255-2745ae', 'target': 'agy', 'status': 'running',
                 'model': 'gemini-4-neon-high', 'cwd': '/tmp/SmartBiz',
                 'conversation_id': 'agy-conv-1', 'started_at': '2026-11-23T15:02:55Z'},
                {'id': 'dsh-261123150446-473b76', 'target': 'dsh', 'status': 'done',
                 'model': 'deepseek-official/deepseek-flash', 'cwd': '/tmp/SmartBiz',
                 'conversation_id': 'session-dsh-1', 'started_at': '2026-11-23T15:04:46Z'},
                {'id': 'agy-261123150500-deadbe', 'target': 'agy', 'status': 'canceled',
                 'model': 'claude-opus-5-5-medium', 'cwd': '/tmp/SmartBiz',
                 'conversation_id': 'agy-conv-canceled', 'started_at': '2026-11-23T15:05:00Z'},
            ]
        }))
        bridge.receive('antigravity', 'PreInvocation', {
            'conversationId': 'agy-conv-1', 'lastUserInput': '/plan [cospan delegation context]',
            'workspacePaths': ['/tmp/SmartBiz'],
        }, self.data)
        bridge.receive('antigravity', 'PreInvocation', {
            'conversationId': 'agy-conv-canceled', 'lastUserInput': '/plan [cospan delegation context]',
            'workspacePaths': ['/tmp/SmartBiz'],
        }, self.data)
        dsh_dir = self.home / '.dsh/storages/session_projcache/sessions'
        dsh_dir.mkdir(parents=True, exist_ok=True)
        (dsh_dir / 'session-dsh-1.json').write_text(json.dumps({
            'record': {'rows': {
                'title': {'val': '[cospan delegation context] - Workspace:'},
                'turnBoundary': {'val': {'openTurnStartSeq': 1, 'lastTurn': 1}},
            }}
        }))
        codex_mon = tm.Monitor(data=self.data, database=codex_db)
        um = p.UnifiedMonitor(self.data, codex=codex_mon, home=self.home)
        um.tick()
        snap = p.read_json(self.data / 'snapshot.json')
        # Only the parent Codex task should appear at top level; canceled subtask is stopped.
        self.assertEqual([t['id'] for t in snap['tasks']], ['codex-parent-a'])
        subs = snap['tasks'][0].get('subtasks', [])
        self.assertEqual({s['id'] for s in subs}, {'antigravity:agy-conv-1', 'deepseek:session-dsh-1'})
        by_id = {s['id']: s for s in subs}
        self.assertEqual(by_id['antigravity:agy-conv-1']['title'], 'Antigravity · gemini-4-neon-high')
        self.assertEqual(by_id['antigravity:agy-conv-1']['status'], 'running')
        self.assertEqual(by_id['deepseek:session-dsh-1']['title'], 'DeepSeek Harness · deepseek-flash')
        self.assertEqual(by_id['deepseek:session-dsh-1']['status'], 'completed')
        # History should also group all three subtasks under the parent Codex thread.
        hist_parent = next(h for h in snap['history'] if h['id'] == 'codex-parent-a')
        self.assertEqual({s['id'] for s in hist_parent.get('subtasks', [])},
                         {'antigravity:agy-conv-1', 'deepseek:session-dsh-1', 'antigravity:agy-conv-canceled'})
        self.assertNotIn('antigravity:agy-conv-1', [h['id'] for h in snap['history']])

    def test_orphaned_completed_and_canceled_cospan_subtasks_never_leak_to_top_level(self):
        state_file = self.home / '.cospan/trajectories/SmartBiz-orphan/state.json'
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps({
            'jobs': [
                {'id': 'dsh-261123155438-d0029b', 'target': 'dsh', 'status': 'done',
                 'model': 'deepseek-flash', 'cwd': '/tmp/SmartBiz',
                 'conversation_id': 'session-dsh-done', 'started_at': '2026-11-23T15:54:38Z'},
                {'id': 'dsh-261123150446-473b76', 'target': 'dsh', 'status': 'canceled',
                 'model': 'deepseek-flash', 'cwd': '/tmp/SmartBiz',
                 'conversation_id': 'session-dsh-canceled', 'started_at': '2026-11-23T15:04:46Z'},
            ]
        }))
        dsh_dir = self.home / '.dsh/storages/session_projcache/sessions'
        dsh_dir.mkdir(parents=True, exist_ok=True)
        # First tick establishes baseline while running, second tick transitions both to completed.
        for sid, title in [
            ('session-dsh-done', '你是独立质检者。请对照用户'),
            ('session-dsh-canceled', '[cospan delegation context] - Workspace:'),
        ]:
            (dsh_dir / f'{sid}.json').write_text(json.dumps({
                'record': {'rows': {
                    'title': {'val': title},
                    'turnBoundary': {'val': {'openTurnStartSeq': 1, 'lastTurn': 1}},
                }}
            }))
        um = self.monitor()
        for sid, title in [
            ('session-dsh-done', '你是独立质检者。请对照用户'),
            ('session-dsh-canceled', '[cospan delegation context] - Workspace:'),
        ]:
            (dsh_dir / f'{sid}.json').write_text(json.dumps({
                'record': {'rows': {
                    'title': {'val': title},
                    'turnBoundary': {'val': {'openTurnStartSeq': None, 'lastStepBoundary': {'kind': 'end'}, 'lastTurn': 1}},
                }}
            }))
        um.tick()
        snap = p.read_json(self.data / 'snapshot.json')
        # Neither the orphaned completed nor the canceled cospan subtask may appear in active tasks.
        self.assertEqual(snap['tasks'], [])
        by_hist = {h['id']: h for h in snap['history']}
        self.assertEqual(by_hist['deepseek:session-dsh-canceled']['status'], 'stopped')

    def test_deepseek_filters_non_workspace_and_archived_sessions_but_keeps_cospan(self):
        dsh_dir = self.home / '.dsh/storages/session_projcache/sessions'
        dsh_dir.mkdir(parents=True, exist_ok=True)
        ws_path = self.home / '.dsh/storages/workspace.json'

        def write_dsh(sid, title, running=True):
            (dsh_dir / f'{sid}.json').write_text(json.dumps({
                'record': {'rows': {
                    'title': {'val': title},
                    'turnBoundary': {'val': {
                        'openTurnStartSeq': 1 if running else None,
                        'lastStepBoundary': {'kind': 'start' if running else 'end'},
                        'lastTurn': 1,
                    }},
                }}
            }))

        write_dsh('session-desktop', '桌面可见对话')
        write_dsh('session-archived', '已归档对话')
        write_dsh('session-headless', 'Remember number 42')
        write_dsh('session-cospan', '你是独立质检者')

        ws_path.write_text(json.dumps({
            'global': {'archivedSessionIds': ['session-archived']},
            'tables': {'workspaces': {
                'ws-1': {'sessionIds': ['session-desktop', 'session-archived']},
            }},
        }))
        state_file = self.home / '.cospan/trajectories/demo/state.json'
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps({
            'jobs': [{
                'id': 'dsh-261124160000-abcdef', 'target': 'dsh', 'status': 'running',
                'model': 'deepseek-flash', 'cwd': '/tmp/demo',
                'conversation_id': 'session-cospan', 'started_at': '2026-11-24T16:00:00Z',
            }],
        }))

        um = self.monitor()
        ids = {t['id'] for t in p.read_json(self.data / 'snapshot.json')['tasks']}
        self.assertIn('deepseek:session-desktop', ids)
        self.assertIn('deepseek:session-cospan', ids)
        self.assertNotIn('deepseek:session-headless', ids)
        self.assertNotIn('deepseek:session-archived', ids)

        hist_ids = {h['id'] for h in p.read_json(self.data / 'snapshot.json')['history']}
        self.assertNotIn('deepseek:session-headless', hist_ids)
        self.assertNotIn('deepseek:session-archived', hist_ids)

        # Updating workspace.json alone must invalidate the provider cache on the next tick.
        ws_path.write_text(json.dumps({
            'global': {'archivedSessionIds': ['session-archived', 'session-desktop']},
            'tables': {'workspaces': {
                'ws-1': {'sessionIds': ['session-desktop', 'session-archived']},
            }},
        }))
        um.tick()
        ids_after = {t['id'] for t in p.read_json(self.data / 'snapshot.json')['tasks']}
        self.assertNotIn('deepseek:session-desktop', ids_after)


if __name__ == '__main__':
    unittest.main()
