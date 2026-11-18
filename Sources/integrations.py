#!/usr/bin/env python3
"""Install additive observer hooks, preserving user configuration and backups."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import time

from providers import PRODUCTS, atomic_json, read_json

COMMON = ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest',
          'Notification', 'Stop', 'SessionEnd']
CLAUDE_EVENTS = COMMON + ['PostToolUseFailure', 'PermissionDenied', 'StopFailure',
                          'Elicitation', 'ElicitationResult']
SPECS = {
    'claude': [('.claude/settings.json', 'nested', CLAUDE_EVENTS)],
    'cursor': [('.cursor/hooks.json', 'cursor', ['beforeSubmitPrompt', 'preToolUse', 'postToolUse', 'stop', 'sessionEnd'])],
    'copilot': [('.copilot/hooks/ai-task-monitor.json', 'copilot', ['userPromptSubmitted', 'preToolUse', 'postToolUse', 'permissionRequest', 'notification', 'agentStop', 'sessionEnd'])],
    'antigravity': [('.gemini/config/hooks.json', 'antigravity', ['PreInvocation', 'PostToolUse', 'Stop'])],
    'gemini': [('.gemini/settings.json', 'nested', ['BeforeAgent', 'BeforeTool', 'AfterTool', 'Notification', 'AfterAgent', 'SessionEnd'])],
    'windsurf': [('.codeium/windsurf/hooks.json', 'windsurf', ['pre_user_prompt', 'post_cascade_response']),
                 ('.config/devin/config.json', 'nested', ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'SessionEnd'])],
    'trae': [('.trae-cn/hooks.json', 'nested', ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']),
             ('.trae/hooks.json', 'nested', ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'])],
    'codebuddy': [('.codebuddy/settings.json', 'nested', COMMON)],
    'qoder': [('.qoder/settings.json', 'nested', COMMON), ('.qoder-cn/settings.json', 'nested', COMMON)],
    'qwencode': [('.qwen/settings.json', 'nested', COMMON)],
    'kimi': [('.kimi-code/config.toml', 'toml', ['UserPromptSubmit', 'TurnStarted', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'PermissionResult', 'Stop', 'SessionEnd'])],
    'opencode': [('.config/opencode/plugins/ai-task-monitor/index.js', 'plugin', [])],
}
MARKER = 'ai-task-monitor'


def hook_command(bridge, provider, event, data):
    return ' '.join(shlex.quote(str(x)) for x in ['/usr/bin/python3', bridge, '--provider', provider, '--event', event, '--data-dir', data])


def owned(value):
    if isinstance(value, dict):
        return any(owned(v) for k, v in value.items() if k in ('command', 'bash', 'hooks') or isinstance(v, (dict, list)))
    if isinstance(value, list):
        return any(owned(v) for v in value)
    return isinstance(value, str) and 'task_bridge.py' in value and '--provider' in value


def without_observer(values):
    """Remove our commands, retaining other commands in a shared hook group."""
    result = []
    for value in values:
        if isinstance(value, dict) and isinstance(value.get('hooks'), list):
            remaining = [hook for hook in value['hooks'] if not owned(hook)]
            if remaining or not owned(value):
                result.append(dict(value, hooks=remaining))
        elif not owned(value):
            result.append(value)
    return result


def merge_config(original, dialect, provider, events, bridge, data):
    if not isinstance(original, dict):
        raise ValueError('配置根节点不是对象，未修改原文件')
    result = copy.deepcopy(original)
    if dialect == 'antigravity':
        current = result.get(MARKER)
        if current and not owned(current):
            raise ValueError('存在同名配置，未覆盖')
        result[MARKER] = {event: [{'type': 'command', 'command': hook_command(bridge, provider, event, data), 'timeout': 5}] for event in events}
        return result
    hooks = result.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('hooks 不是对象，未修改原文件')
    if dialect in ('cursor', 'copilot'):
        result.setdefault('version', 1)
        if result['version'] != 1:
            raise ValueError('不支持的 hooks 版本，未修改原文件')
    for event in events:
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            raise ValueError('hooks.' + event + ' 不是数组，未修改原文件')
        existing = without_observer(existing)
        cmd = hook_command(bridge, provider, event, data)
        if dialect == 'cursor':
            new = {'command': cmd}
        elif dialect == 'copilot':
            new = {'type': 'command', 'bash': cmd, 'timeoutSec': 5}
        elif dialect == 'windsurf':
            new = {'command': cmd, 'show_output': False}
        else:
            new = {'hooks': [{'type': 'command', 'command': cmd, 'timeout': 5000 if provider == 'gemini' else 5}]}
        hooks[event] = existing + [new]
    return result


def merge_toml(text, provider, events, bridge, data):
    begin, end = '# BEGIN ai-task-monitor', '# END ai-task-monitor'
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise ValueError('接入配置标记不完整，未修改原文件')
    text = re.sub(r'(?m)^# BEGIN ai-task-monitor\n.*?^# END ai-task-monitor\n?', '', text, flags=re.S)
    block = [begin]
    for event in events:
        block.extend(['[[hooks]]', 'event = ' + json.dumps(event),
                      'command = ' + json.dumps(hook_command(bridge, provider, event, data)), 'timeout = 5', ''])
    block.append(end)
    return text.rstrip() + '\n\n' + '\n'.join(block) + '\n'


def install(home, data, bridge, providers=None, remove=False):
    home, data, bridge = Path(home), Path(data), Path(bridge).resolve()
    report = read_json(data / 'integrations.json', {})
    requested = set(providers or SPECS)
    for provider in sorted(requested):
        if provider not in SPECS:
            continue
        paths, errors = [], []
        for relative, dialect, events in SPECS[provider]:
            path = home / relative
            if remove and not path.exists():
                continue
            # Autoconfiguration only touches clients already present. An
            # explicit provider request also prepares a future installation.
            components = Path(relative).parts
            root = home.joinpath(*components[:2]) if components[0] == '.config' else home / components[0]
            app_present = any((base / (name + '.app')).exists() for base in (Path('/Applications'), home / 'Applications') for name in PRODUCTS[provider][1])
            if providers is None and not root.exists() and not app_present:
                continue
            try:
                if dialect == 'plugin':
                    template = Path(__file__).with_name('opencode-plugin')
                    for filename in ('package.json', 'index.js'):
                        target = path.with_name(filename)
                        before = target.read_text() if target.exists() else ''
                        if before and 'ai-task-monitor' not in before:
                            raise ValueError('同名插件目录已被占用，未覆盖')
                        after = (template / filename).read_text().replace('__BRIDGE__', json.dumps(str(bridge))).replace('__DATA__', json.dumps(str(data)))
                        if before and (remove or after != before):
                            backup = data / 'backups' / ('hooks-' + str(time.time_ns())) / relative
                            backup = backup.with_name(filename)
                            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                            shutil.copy2(target, backup)
                        if remove:
                            if target.exists():
                                target.unlink()
                        elif before != after:
                            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                            temporary = target.with_suffix('.tmp')
                            temporary.write_text(after)
                            temporary.replace(target)
                    paths.append(str(path))
                    continue
                before = path.read_text() if path.exists() else ''
                if dialect == 'toml':
                    after = merge_toml(before, provider, events, bridge, data)
                    if remove:
                        after = re.sub(r'(?m)^# BEGIN ai-task-monitor\n.*?^# END ai-task-monitor\n?', '', before, flags=re.S)
                else:
                    original = json.loads(before) if before.strip() else {}
                    if remove:
                        merged = copy.deepcopy(original)
                        if dialect == 'antigravity':
                            if owned(merged.get(MARKER)):
                                merged.pop(MARKER, None)
                        else:
                            for event, values in merged.get('hooks', {}).items():
                                if isinstance(values, list):
                                    merged['hooks'][event] = without_observer(values)
                    else:
                        merged = merge_config(original, dialect, provider, events, bridge, data)
                    after = json.dumps(merged, ensure_ascii=False, indent=2) + '\n'
                if after != before:
                    if path.exists():
                        backup = data / 'backups' / ('hooks-' + str(time.time_ns())) / relative
                        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        shutil.copy2(path, backup)
                        backup.chmod(0o600)
                    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    temp = path.with_name(path.name + '.ai-task-monitor.tmp')
                    temp.write_text(after)
                    temp.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
                    temp.replace(path)
                paths.append(str(path))
            except (OSError, ValueError, TypeError) as error:
                errors.append(str(path) + ': ' + str(error))
        report[provider] = dict(installed=bool(paths) and not remove, paths=paths, error='; '.join(errors), updated=time.time())
    atomic_json(data / 'integrations.json', report)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--provider', action='append', choices=SPECS)
    parser.add_argument('--remove', action='store_true')
    parser.add_argument('--home', default=str(Path.home()))
    parser.add_argument('--data-dir', default=os.environ.get('TASK_PANEL_DATA_DIR', str(Path.home() / '.codex/task-manager')))
    parser.add_argument('--bridge', default=str(Path(__file__).with_name('task_bridge.py')))
    args = parser.parse_args()
    result = install(args.home, args.data_dir, args.bridge, args.provider, args.remove)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
