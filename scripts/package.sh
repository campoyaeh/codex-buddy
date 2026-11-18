#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="${1:-0.1.0}"
[[ "$version" == <->.<->.<-> ]]
./scripts/build.sh "$version"
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-buddy-package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
mkdir -p dist
ditto "build/工头喵.app" "$package_dir/工头喵.app"
ln -s /Applications "$package_dir/Applications"
cat > "$package_dir/安装说明.txt" <<'TXT'
工头喵（Codex Buddy）— macOS 任务浮窗

安装方法（推荐）：
1. 将「工头喵.app」拖入右侧的「Applications（应用程序）」文件夹。
2. 在「应用程序」中双击打开「工头喵」。
3. 首次打开如遇 macOS 提示“无法验证开发者”，可前往
   「系统设置 → 隐私与安全性」点击「仍要打开」，或在图标上右键选择「打开」。

使用说明：
- 适用于 macOS 12 或更新版本，支持 Apple Silicon 和 Intel（需要系统 Python 3）。
- 首次打开会自动打开主面板并尝试接入本机已安装的 AI 客户端；
  可在主面板勾选「登录时自动启动」，或点击「兼容与接入」查看/移除接入配置。
- 任务数据与设置保存在 ~/.codex/task-manager。
- Antigravity 一键跳转可从「主面板 → 任务跳转授权」开启辅助功能权限。

源码与发布地址 https://github.com/campoyaeh/codex-buddy
TXT
image_path="$PWD/dist/Codex-Buddy-${version}-macOS-universal.dmg"
hdiutil create -volname 'Codex Buddy' -srcfolder "$package_dir" -format UDZO -ov "$image_path"
(cd dist && shasum -a 256 "${image_path:t}" > "${image_path:t}.sha256")
print "$image_path"
