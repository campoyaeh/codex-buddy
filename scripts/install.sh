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
bundle='工头喵.app'
executable='Contents/MacOS/codex-task-complete-popup'
[[ -x "build/$bundle/$executable" && -f build/task_monitor.py ]]
/usr/bin/codesign --verify --strict "build/$bundle"
backup_dir="$HOME/.codex/task-manager/backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir" "$HOME/.codex/bin" "$HOME/Library/LaunchAgents"
app_path="$HOME/.codex/bin/$bundle"
app_stage=$(mktemp -d "$HOME/.codex/bin/.buddy-install.XXXXXX")
trap 'rm -r "$app_stage"' EXIT
ditto "build/$bundle" "$app_stage/$bundle"
/usr/bin/codesign --verify --strict "$app_stage/$bundle"
for source_file in codex-task-complete-popup task_monitor.py providers.py task_bridge.py integrations.py CodexTaskCompletePopup.m Celebration.h Celebration.m DesktopObserver.h DesktopObserver.m Mascot.h Mascot.m PanelTheme.h PanelTheme.m AntigravityNavigation.h AntigravityNavigation.m; do
    if [[ -f "$HOME/.codex/bin/$source_file" ]]; then
        cp "$HOME/.codex/bin/$source_file" "$backup_dir/"
    fi
done
if [[ -d "$HOME/.codex/bin/opencode-plugin" ]]; then
    cp -R "$HOME/.codex/bin/opencode-plugin" "$backup_dir/"
fi
agent_plist="$HOME/Library/LaunchAgents/com.openai.codex-task-complete-popup.watch.plist"
if [[ -f "$agent_plist" ]]; then
    cp "$agent_plist" "$backup_dir/"
fi
/usr/bin/python3 - "$agent_plist.new" "$HOME" "$app_path/$executable" <<'PY'
import plistlib
import sys
from pathlib import Path

home = Path(sys.argv[2])
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump({
        'Label': 'com.openai.codex-task-complete-popup.watch',
        'ProgramArguments': [sys.argv[3], '--watch'],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
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
for source_file in providers.py task_bridge.py integrations.py; do
    cp "build/$source_file" "$HOME/.codex/bin/$source_file.new"
    mv "$HOME/.codex/bin/$source_file.new" "$HOME/.codex/bin/$source_file"
done
mkdir -p "$HOME/.codex/bin/opencode-plugin"
cp build/opencode-plugin/index.js build/opencode-plugin/package.json "$HOME/.codex/bin/opencode-plugin/"
if [[ -d Sources ]]; then
    cp Sources/Celebration.h Sources/Celebration.m "$HOME/.codex/bin/"
    cp Sources/Mascot.h Sources/Mascot.m "$HOME/.codex/bin/"
    cp Sources/PanelTheme.h Sources/PanelTheme.m "$HOME/.codex/bin/"
    cp Sources/AntigravityNavigation.h Sources/AntigravityNavigation.m "$HOME/.codex/bin/"
    cp Sources/TaskPanel.m "$HOME/.codex/bin/CodexTaskCompletePopup.m"
fi
cat > "$app_stage/codex-task-complete-popup" <<'SH'
#!/bin/zsh
exec "${0:A:h}/工头喵.app/Contents/MacOS/codex-task-complete-popup" "$@"
SH
chmod +x "$app_stage/codex-task-complete-popup"
service="gui/$(id -u)/com.openai.codex-task-complete-popup.watch"
if launchctl print "$service" >/dev/null 2>&1; then
    if ! launchctl bootout "$service" && launchctl print "$service" >/dev/null 2>&1; then
        exit 1
    fi
fi
if [[ -d "$app_path" ]]; then
    mv "$app_path" "$backup_dir/"
fi
if ! mv "$app_stage/$bundle" "$app_path"; then
    if [[ -d "$backup_dir/$bundle" ]]; then
        mv "$backup_dir/$bundle" "$app_path"
    fi
    if [[ -f "$agent_plist" ]]; then
        launchctl bootstrap "gui/$(id -u)" "$agent_plist" || true
    fi
    exit 1
fi
mv "$app_stage/codex-task-complete-popup" "$HOME/.codex/bin/codex-task-complete-popup"
mv "$agent_plist.new" "$agent_plist"
launch_ready=0
for attempt in {1..10}; do
    if launchctl bootstrap "gui/$(id -u)" "$agent_plist" > "$HOME/.codex/task-manager/launch-install.log" 2>&1; then
        launch_ready=1
        break
    fi
    # bootout can leave the old service visible while it finishes unloading.
    # A surviving old entry does not mean this bootstrap succeeded.
    sleep 0.3
done
if (( launch_ready == 0 )); then
    cat "$HOME/.codex/task-manager/launch-install.log" >&2
    exit 1
fi
launchctl print "$service" >/dev/null
legacy_jump_path="$HOME/.codex/bin/工头喵跳转助手.app"
if [[ -d "$legacy_jump_path" ]]; then
    mv "$legacy_jump_path" "$backup_dir/"
fi
/usr/bin/python3 "$HOME/.codex/bin/integrations.py" > "$HOME/.codex/task-manager/integration-install.log"
print '工头喵已安装并启动，将在登录时自动运行。点击菜单栏角色图标进入主面板，或右键选择「退出应用」。'
print '任务监测无需辅助功能权限。Antigravity 一键跳转由「工头喵」直接执行，可在主面板进入「任务跳转授权」。'
print "原有文件备份于 $backup_dir"
