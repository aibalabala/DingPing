#!/bin/bash
# Also signed inside the App bundle so the untrusted app can offer this tool.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上运行。'; exit 1; fi
from_installer=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --from-installer ]]; then from_installer=1
  else echo '不支持的参数。'; exit 2; fi
fi

target_app="$HOME/Applications/定屏.app"
bundle_id=local.dingping.fixedsplit
expected_version=0.5.1
expected_build=8
log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/DMG授权修复日志.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1

finish() {
  local result=$?
  trap - EXIT
  if [[ $result -ne 0 ]]; then printf '\n未完成授权引导。日志：%s\n' "$log_file"; fi
  if [[ "$from_installer" == 0 && -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

field() {
  /usr/libexec/PlistBuddy -c "Print :${2}" "$1/Contents/Info.plist" 2>/dev/null
}
verify_current() {
  [[ -d "$target_app" && ! -L "$target_app" &&
     "$(field "$target_app" CFBundleIdentifier || true)" == "$bundle_id" &&
     "$(field "$target_app" CFBundleShortVersionString || true)" == "$expected_version" &&
     "$(field "$target_app" CFBundleVersion || true)" == "$expected_build" &&
     -x "$target_app/Contents/MacOS/DingPing" ]] &&
    /usr/bin/codesign --verify --deep --strict "$target_app" >/dev/null 2>&1
}
cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$target_app" 2>&1 |
    /usr/bin/awk -F= '/^CDHash=/{print $2; exit}'
}
running_pids() {
  /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x DingPing || true
}

echo '定屏 · 只修复当前版本的辅助功能授权'
printf '准确位置：%s\n' "$target_app"
if ! verify_current; then
  echo '未找到已验证的 v0.5.1（构建 8），不重置旧版权限。请先从本 DMG 安装。'
  exit 3
fi
expected_hash="$(cdhash)"
if [[ -z "$expected_hash" ]]; then echo '无法核对签名指纹，未改动权限。'; exit 3; fi
if [[ -e /Applications/定屏.app ]]; then
  printf '另外发现一份同名应用：/Applications/定屏.app（版本 %s）。请勿选错。\n' \
    "$(field /Applications/定屏.app CFBundleShortVersionString || true)"
fi
if [[ ! -t 0 ]]; then
  echo '请双击本工具，在交互式终端里处理。当前没有改动任何权限。'
  exit 4
fi

# When started from inside the app, give it a moment to terminate itself.
for ((attempt=0;attempt<20;attempt++)); do
  [[ -z "$(running_pids)" ]] && break
  /bin/sleep .25
done
if [[ -n "$(running_pids)" ]]; then
  echo '定屏仍在运行。请从菜单栏选择「退出定屏」，然后重新双击修复工具。'
  while read -r pid; do
    [[ -n "$pid" ]] && /bin/ps -ww -p "$pid" -o pid= -o command= 2>/dev/null || true
  done <<< "$(running_pids)"
  exit 5
fi

echo ''
echo '[1/3] 清理此应用标识的旧辅助功能决定'
if /usr/bin/tccutil reset Accessibility "$bundle_id"; then
  echo '已请求系统仅重置定屏的辅助功能记录。'
else
  echo '系统未接受按应用标识重置；请在下一步手动移除列表里的旧定屏条目。'
  echo '没有重置其他应用，也不会直接修改系统权限数据库。'
fi

echo ''
echo '[2/3] 请在系统设置中完成以下步骤'
echo '  1. 打开「隐私与安全性 → 辅助功能」。'
echo '  2. 如果列表中仍有「定屏」或「定屏.app」，选中并用列表下方的「－」移除旧条目。'
echo '  3. 点「＋」；选择窗口按 Command + Shift + G，进入以下文件夹：'
printf '     %s\n' "$HOME/Applications"
echo '  4. 在该文件夹选中「定屏.app」，点「打开」，然后开启它的开关。'
echo '请不要从 /Applications、下载文件夹、备份或 DMG 里选择同名应用。'
echo '系统授权必须由你操作，脚本不会代替你打开开关。'
/usr/bin/open -R "$target_app" >/dev/null 2>&1 || true
/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true

if ! read -r -p '完成移除旧条目并重新添加后，回到这里按回车启动定屏：' _answer; then
  echo '尚未启动。可稍后从个人 Applications 手动打开。'
  exit 6
fi
if ! verify_current || [[ "$(cdhash)" != "$expected_hash" ]] || [[ -n "$(running_pids)" ]]; then
  echo '应用已变化或已有定屏进程，未启动其他副本。'
  exit 7
fi
echo ''
echo '[3/3] 启动经过验证的准确路径'
/usr/bin/open -n -a "$target_app"
echo '请在新打开的定屏里看「权限诊断」：版本 0.5.1（构建 8），辅助功能检测应为已授权。'
echo '若仍显示未授权，请复制权限诊断与本日志；不要重置其他应用或系统全局权限。'
