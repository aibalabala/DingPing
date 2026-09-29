#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上运行这个工具。'; exit 1; fi
source "$project_dir/Installer/common.sh"
log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/已安装版本.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1
finish() {
  local result=$?
  trap - EXIT
  printf '\n检查报告：%s\n' "$log_file"
  if [[ -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
dp_load_release "$project_dir" || { echo '无法读取安装包信息。'; exit 1; }
app="$HOME/Applications/定屏.app"
printf '本包应用：%s（构建 %s）\n\n' "$DP_VERSION" "$DP_BUILD"
dp_show_app "$app"
if dp_matches_release "$app"; then
  echo '检查结果：当前应用版本、构建号、内容指纹和签名匹配。'
  /usr/bin/open -R "$app" >/dev/null 2>&1 || true
else
  printf '检查结果：%s。\n' "$DP_MISMATCH"
fi
dp_show_other_copy
echo ''
dp_require_stopped || true
echo '本工具不安装、不启动定屏，也不更改任何权限。'
echo '授权状态请以正在运行的定屏中的「权限诊断」为准。'
