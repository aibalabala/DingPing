#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
combined=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --combined ]]; then combined=1; else echo '不支持的修复参数。'; exit 2; fi
fi
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上运行这个工具。'; exit 1; fi
source "$project_dir/Installer/common.sh"
app="$HOME/Applications/定屏.app"
log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/权限修复日志.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1
finish() {
  local result=$?
  trap - EXIT
  if [[ $result -ne 0 ]]; then printf '\n修复未完成。日志：%s\n' "$log_file"; fi
  if [[ "$combined" == 0 && -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
dp_load_release "$project_dir" || { echo '安装包信息无法读取，请重新完整解压。'; exit 1; }
bundle_id="$DP_BUNDLE_ID"
echo '定屏 · 为当前安装修复辅助功能授权'
printf '需要的应用版本：%s（构建 %s）\n' "$DP_VERSION" "$DP_BUILD"
printf '这个工具只重置定屏（%s）的辅助功能授权。\n' "${bundle_id}"
echo '修复不会重新编译或重新签名 App；完成后仍需你在系统设置中打开开关。'
printf '日志：%s\n\n' "$log_file"
dp_show_app "$app"
dp_show_other_copy

# A stale or missing application must never consume the old grant.
dp_require_current "$app" || exit 2
if [[ ! -x /usr/bin/tccutil ]]; then echo '找不到系统的 tccutil，已停止。'; exit 3; fi
if [[ ! -t 0 ]]; then
  echo '请直接双击本工具，在有交互的终端中完成授权。当前没有重置权限。'
  exit 4
fi

echo ''
echo '[1/3] 已确认当前版本和安装位置，正在重置定屏自己的授权记录……'
dp_require_current "$app" || exit 5
if ! dp_tcc_reset "$bundle_id"; then
  echo '系统未接受按应用标识重置。请在下一步手动移除旧定屏条目；没有执行全局重置。'
fi

echo '[2/3] 请在系统设置中为下面这份应用重新授权：'
printf '%s\n\n' "$app"
echo '  1. 进入「隐私与安全性 → 辅助功能」。如果仍有旧定屏条目，只移除定屏。'
echo '  2. 点「+」，在选择窗口按 Command + Shift + G。'
printf '  3. 粘贴文件夹 %s，回车；选中「定屏.app」再点「打开」。\n' "$HOME/Applications"
echo '  4. 开启「定屏」旁的开关。列表名称仍然是定屏，不需要找第二个新版条目。'
echo '如果列表没有刷新，先切换到其他设置页面，再回到辅助功能。'
echo ''
/usr/bin/open -R "$app" >/dev/null 2>&1 || true
/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true
if ! read -r -p '完成添加并打开开关后，回到这里按回车启动；暂不授权请按 Control + C：' _answer; then
  echo '尚未启动应用。稍后可从上面的完整路径打开。'
  exit 6
fi

echo ''
echo '[3/3] 正在打开这份已验证的应用……'
# Revalidate after the user has spent time in Settings; never fall back to an old copy.
if ! dp_launch_current "$app"; then
  echo '没有完成启动，请查看上面的版本或进程提示。不要重复重置其他应用的权限。'
  exit 7
fi
echo '启动请求已发送。请在定屏的「权限诊断」确认：'
printf '  版本：%s（构建 %s）\n  正在运行的应用：%s\n' "$DP_VERSION" "$DP_BUILD" "$app"
echo '  辅助功能检测：已授权'
echo '上面是需要核对的结果，脚本自身无法代替定屏进程检测授权状态。'
echo '如果仍未授权，请复制定屏的权限诊断，并保留此日志。'
