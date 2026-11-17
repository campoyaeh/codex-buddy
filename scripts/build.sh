#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework AppKit -framework QuartzCore Sources/TaskPanel.m Sources/Celebration.m -o build/codex-task-complete-popup
cp Sources/task_monitor.py build/task_monitor.py
