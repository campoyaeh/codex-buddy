#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -z "${1:-}" || "$1" == <->.<->.<-> ]]
mkdir -p build
clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -lsqlite3 -framework AppKit -framework QuartzCore -framework CoreImage -framework CoreVideo -weak_framework Vision -framework ApplicationServices -framework Carbon Sources/TaskPanel.m Sources/Celebration.m Sources/Mascot.m Sources/PanelTheme.m Sources/AntigravityNavigation.m Sources/InputMirror.m Sources/Updater.m -o build/codex-task-complete-popup
bundle="build/工头喵.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/avatars" build/avatars
cp Sources/Info.plist "$bundle/Contents/Info.plist"
cp assets/foreman-app-icon.icns "$bundle/Contents/Resources/Foreman.icns"
if [[ -d assets/avatars ]]; then
    cp assets/avatars/*.png "$bundle/Contents/Resources/avatars/"
    cp assets/avatars/*.png build/avatars/
fi
if [[ -n "${1:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $1" -c "Add :CFBundleVersion string $1" "$bundle/Contents/Info.plist"
fi
cp build/codex-task-complete-popup "$bundle/Contents/MacOS/"
cp Sources/task_monitor.py Sources/providers.py Sources/task_bridge.py Sources/integrations.py "$bundle/Contents/Resources/"
mkdir -p "$bundle/Contents/Resources/opencode-plugin"
cp Sources/opencode-plugin/index.js Sources/opencode-plugin/package.json "$bundle/Contents/Resources/opencode-plugin/"
sign_identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Codex Buddy Local Signing"'; then
        sign_identity="Codex Buddy Local Signing"
    else
        sign_identity="-"
    fi
fi
if [[ "$sign_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$bundle"
else
    /usr/bin/codesign --force --deep --sign "$sign_identity" "$bundle"
fi
cp Sources/task_monitor.py Sources/providers.py Sources/task_bridge.py Sources/integrations.py build/
mkdir -p build/opencode-plugin
cp Sources/opencode-plugin/index.js Sources/opencode-plugin/package.json build/opencode-plugin/
