#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $(id -u) == 0 ]]; then
    print -u2 '请以当前登录用户运行安装程序，无需 sudo。'
    exit 1
fi
if ! /usr/bin/python3 --version >/dev/null 2>&1; then
    print -u2 '请先安装 Python 3 和 Apple Command Line Tools（xcode-select --install）。'
    exit 1
fi
if [[ -d Sources ]]; then
    ./scripts/build.sh
fi
[[ -x build/codex-task-complete-popup && -f build/task_monitor.py ]]
backup_dir="$HOME/.codex/task-manager/backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir" "$HOME/.codex/bin" "$HOME/Library/LaunchAgents"
for source_file in codex-task-complete-popup task_monitor.py CodexTaskCompletePopup.m Celebration.h Celebration.m; do
    if [[ -f "$HOME/.codex/bin/$source_file" ]]; then
        cp "$HOME/.codex/bin/$source_file" "$backup_dir/"
    fi
done
agent_plist="$HOME/Library/LaunchAgents/com.openai.codex-task-complete-popup.watch.plist"
if [[ -f "$agent_plist" ]]; then
    cp "$agent_plist" "$backup_dir/"
fi
/usr/bin/python3 - "$agent_plist.new" "$HOME" <<'PY'
import plistlib
import sys
from pathlib import Path

home = Path(sys.argv[2])
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump({
        'Label': 'com.openai.codex-task-complete-popup.watch',
        'ProgramArguments': [str(home / '.codex/bin/codex-task-complete-popup'), '--watch'],
        'RunAtLoad': True,
        'KeepAlive': True,
        'ProcessType': 'Interactive',
        'LimitLoadToSessionType': 'Aqua',
        'ThrottleInterval': 5,
        'StandardOutPath': str(home / '.codex/task-complete-popup-watch.log'),
        'StandardErrorPath': str(home / '.codex/task-complete-popup-watch.log'),
    }, handle)
PY
/usr/bin/plutil -lint "$agent_plist.new"
cp build/task_monitor.py "$HOME/.codex/bin/task_monitor.py.new"
mv "$HOME/.codex/bin/task_monitor.py.new" "$HOME/.codex/bin/task_monitor.py"
if [[ -d Sources ]]; then
    cp Sources/Celebration.h Sources/Celebration.m "$HOME/.codex/bin/"
    cp Sources/TaskPanel.m "$HOME/.codex/bin/CodexTaskCompletePopup.m"
fi
cp build/codex-task-complete-popup "$HOME/.codex/bin/codex-task-complete-popup.new"
mv "$HOME/.codex/bin/codex-task-complete-popup.new" "$HOME/.codex/bin/codex-task-complete-popup"
service="gui/$(id -u)/com.openai.codex-task-complete-popup.watch"
if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service"
fi
mv "$agent_plist.new" "$agent_plist"
launchctl bootstrap "gui/$(id -u)" "$agent_plist"
launchctl print "$service" >/dev/null
print 'Codex Buddy 已安装并启动，将在登录时自动运行。'
print "原有文件备份于 $backup_dir"
