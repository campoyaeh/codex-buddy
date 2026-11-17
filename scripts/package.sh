#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="${1:-0.1.0}"
[[ "$version" == <->.<->.<-> ]]
./scripts/build.sh
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-buddy-package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
bundle="$package_dir/Codex Buddy"
mkdir -p "$bundle/build" "$bundle/scripts" dist
cp build/codex-task-complete-popup build/task_monitor.py "$bundle/build/"
cp scripts/install.sh "$bundle/scripts/"
cat > "$bundle/安装.command" <<'SH'
#!/bin/zsh
cd "${0:A:h}"
./scripts/install.sh
result=$?
if (( result != 0 )); then
    print -u2 '安装失败，请检查上方错误信息。'
fi
read -k 1 '?按任意键关闭窗口…'
exit $result
SH
chmod +x "$bundle/安装.command"
cat > "$bundle/安装说明.txt" <<'TXT'
Codex Buddy — macOS 任务浮窗

适用于 macOS 12 或更新版本，支持 Apple Silicon 和 Intel。
需要已安装并使用 Codex 桌面版，以及 /usr/bin/python3。
缺少 Python 3 时，可先在终端执行 xcode-select --install。

将此文件夹复制到本地后，双击「安装.command」。安装无需 sudo。
安装后自动启动，并在用户登录时运行。
安装位置为 ~/.codex/bin，设置位于 ~/.codex/task-manager。
已有程序和启动配置备份到 ~/.codex/task-manager/backups。

此社区版本未使用 Apple Developer ID 签名，也未经过 Apple 公证。
macOS 可能要求通过系统设置中的「隐私与安全性」批准运行。
仅在核对下载来源和 SHA256 后批准。

源码与发布地址 https://github.com/campoyaeh/codex-buddy
TXT
image_path="$PWD/dist/Codex-Buddy-${version}-macOS-universal.dmg"
hdiutil create -volname 'Codex Buddy' -srcfolder "$bundle" -format UDZO -ov "$image_path"
(cd dist && shasum -a 256 "${image_path:t}" > "${image_path:t}.sha256")
print "$image_path"
