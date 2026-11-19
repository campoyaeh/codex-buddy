#!/usr/bin/env python3
"""Fail-open hook receiver. Never prints decisions or changes client actions."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import uuid

from providers import PRODUCTS, atomic_json, read_json, task


START = {'UserPromptSubmit', 'beforeSubmitPrompt', 'userPromptSubmitted', 'BeforeAgent',
         'pre_user_prompt', 'TurnStarted', 'PreInvocation'}
ACTIVE = {'PreToolUse', 'PostToolUse', 'preToolUse', 'postToolUse', 'BeforeTool',
          'AfterTool', 'PermissionResult', 'ElicitationResult', 'PostToolUseFailure', 'PermissionDenied'}
DONE = {'Stop', 'stop', 'agentStop', 'AfterAgent', 'post_cascade_response', 'TurnCompleted'}
WAIT = {'PermissionRequest', 'permissionRequest', 'Elicitation'}
END = {'SessionEnd', 'sessionEnd', 'session.end', 'StopFailure'}


def receive(provider, event, payload, data, now=None):
    if provider not in PRODUCTS or not isinstance(payload, dict):
        return None
    if provider == 'claude' and os.environ.get('DEVIN_PROJECT_DIR'):
        provider = 'windsurf'
    now = now or time.time()
    # Subagent ends do not complete the parent. Registered hooks observe only
    # the main lifecycle; explicit subagent payloads are excluded as well.
    if (event in ('SubagentStop', 'subagentStop') or payload.get('is_subagent')
            or (provider == 'claude' and payload.get('agent_id'))):
        return None
    session = next((payload.get(k) for k in ('session_id', 'sessionId', 'conversation_id', 'conversationId', 'cascade_id') if payload.get(k)), None)
    if not isinstance(session, str) or len(session) > 512:
        return None  # Never merge concurrent sessions using cwd as identity.
    key = provider + ':' + session
    digest = hashlib.sha256(key.encode()).hexdigest()
    root = Path(data) / 'events'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = root / (digest + '.json')
    with (root / (digest + '.lock')).open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = read_json(path, {})
        status = previous.get('status', 'stopped')
        notification = payload.get('notification_type', payload.get('notificationType', payload.get('type', '')))
        if payload.get('event_id') and previous.get('event_id') == payload['event_id']:
            return previous
        if event == 'SessionMetadata':
            pass
        elif event in WAIT:
            status = 'waiting'
        elif event in ('Notification', 'notification'):
            if notification not in ('permission_prompt', 'elicitation_dialog', 'idle_prompt'):
                return None
            if notification == 'idle_prompt' and status == 'completed':
                return None
            status = 'waiting'
        elif event in START or event in ACTIVE:
            status = 'running'
            tool_name = payload.get('tool_name') or payload.get('toolName') or (payload.get('toolCall') or {}).get('name')
            if event in ('PreToolUse', 'preToolUse', 'BeforeTool') and tool_name in ('AskUserQuestion', 'ask_user_question', 'ask_user', 'request_user_input', 'ask_followup_question'):
                status = 'waiting'
        elif event in DONE:
            termination = str(payload.get('terminationReason') or '').lower()
            raw_status = str(payload.get('status') or '').lower()
            if provider == 'antigravity' and payload.get('fullyIdle') is False:
                status = 'running'
            elif (payload.get('error')
                  or termination in ('error', 'max_steps_exceeded', 'max_invocations', 'max_forced_invocations',
                                     'max_token_budget_exceeded', 'canceled', 'cancelled', 'user_canceled',
                                     'user_cancelled', 'terminal_custom_hook')
                  or raw_status in ('aborted', 'error', 'canceled', 'cancelled')):
                status = 'stopped'
            elif previous.get('status') == 'waiting':
                status = 'waiting'
            else:
                status = 'completed'
        elif event in END:
            status = 'completed' if previous.get('status') == 'completed' and event != 'StopFailure' and payload.get('reason') not in ('abort', 'error', 'timeout') else 'stopped'
        else:
            return None
        waiting_kind = 'approval' if event in WAIT else ('question' if status == 'waiting' else '')
        pending = {}
        if provider == 'claude':
            # Tool hooks from concurrent main-agent calls can interleave. An
            # unrelated tool finishing must not clear a pending question.
            pending = dict(previous.get('pending', {}))
            tool = payload.get('tool_name', '')
            token = payload.get('tool_use_id') or tool or 'permission'
            # PermissionRequest omits tool_use_id in Claude's protocol. Match
            # the eventual result using its tool name and original input.
            permission_token = 'permission:' + tool + ':' + hashlib.sha256(json.dumps(payload.get('tool_input', {}), sort_keys=True).encode()).hexdigest()
            if event in START:
                pending.clear()
            if event == 'PermissionRequest':
                pending[permission_token] = 'approval'
            elif event == 'PreToolUse' and tool == 'AskUserQuestion':
                pending[token] = 'question'
            elif event in ('PostToolUse', 'PostToolUseFailure', 'PermissionDenied'):
                pending.pop(token, None)
                pending.pop(permission_token, None)
            elif event == 'Elicitation':
                pending['mcp:' + str(payload.get('elicitation_id') or payload.get('mcp_server_name', ''))] = 'question'
            elif event == 'ElicitationResult':
                pending.pop('mcp:' + str(payload.get('elicitation_id') or payload.get('mcp_server_name', '')), None)
            if event in END or (event == 'PostToolUseFailure' and payload.get('is_interrupt')):
                status = 'stopped' if event != 'SessionEnd' else status
                pending.clear()
            elif pending:
                status = 'waiting'
            if status == 'waiting':
                waiting_kind = 'question' if 'question' in pending.values() else (next(iter(pending.values()), '') or previous.get('waiting_kind') or waiting_kind)
            else:
                waiting_kind = ''
        explicit_turn = next((payload.get(k) for k in ('turn_id', 'turnId', 'generation_id', 'generationId', 'prompt_id') if payload.get(k)), '')
        turn = str(explicit_turn or previous.get('turn') or uuid.uuid4())
        if event in START and (provider == 'claude' or previous.get('status') in (None, 'completed', 'stopped')) and not explicit_turn:
            turn = str(uuid.uuid4())
        # Ignore late explicit-turn results after a newer turn has started.
        if explicit_turn and event in DONE | END and previous.get('turn') and str(explicit_turn) != previous['turn']:
            return None
        roots = payload.get('workspace_roots') or payload.get('workspacePaths') or []
        cwd = payload.get('cwd') or payload.get('working_directory') or (roots[0] if roots else '')
        prompt = payload.get('prompt') or payload.get('user_prompt') or payload.get('lastUserInput') or payload.get('tool_info', {}).get('user_prompt')
        if provider == 'qwencode':
            prompt = payload.get('submitted_prompt', '')
        if not isinstance(prompt, str):
            prompt = ''
        title = payload.get('title') or previous.get('title') or (Path(cwd).name if cwd else PRODUCTS[provider][0])
        if prompt and event in START:
            title = prompt.splitlines()[0].strip()[:160] or title
        entry = task(provider, session, turn, title, status, updated=now,
                     navigation='application', app=PRODUCTS[provider][1][0] if PRODUCTS[provider][1] else '',
                     project=Path(cwd).name if cwd else '', event=event,
                     event_id=payload.get('event_id', ''),
                     waiting_kind=waiting_kind)
        if provider == 'claude':
            entry['pending'] = pending
        # Only known, non-mutating session links. Other clients return to the
        # application; terminal sessions offer a copyable resume command in UI.
        if provider in ('claude', 'qwencode', 'gemini', 'copilot', 'kimi'):
            commands = {'claude': 'claude --resume', 'qwencode': 'qwen --resume', 'gemini': 'gemini --resume',
                        'copilot': 'copilot --resume', 'kimi': 'kimi --session'}
            import shlex
            entry['resume_command'] = commands[provider] + ' ' + shlex.quote(session)
        atomic_json(path, entry)
        return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--provider', required=True, choices=PRODUCTS)
    parser.add_argument('--event', required=True)
    parser.add_argument('--data-dir', default=os.environ.get('TASK_PANEL_DATA_DIR', str(Path.home() / '.codex/task-manager')))
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(2 * 1024 * 1024)
        receive(args.provider, args.event, json.loads(raw), Path(args.data_dir))
    except Exception:
        # An observer must not break approval, inject context or block an agent.
        pass


if __name__ == '__main__':
    main()
