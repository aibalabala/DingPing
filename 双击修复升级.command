#!/bin/bash
# One entry point for the reported old-version / stale-permission problem.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上双击这个工具。'; exit 1; fi
log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/升级修复日志.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1
finish() {
  local result=$?
  trap - EXIT
  if [[ $result -ne 0 ]]; then
    echo '流程已停止，请按上面的原因处理后重试。没有跳过检查继续执行后续步骤。'
  fi
  printf '完整日志：%s\n' "$log_file"
  if [[ -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo '定屏 · 修复升级与授权'
echo '本工具先确认新版安装成功，再为这份应用修复辅助功能授权。'
echo '如果已安装相同版本，会保留 App，不重复编译或签名。'
echo '请先从菜单栏退出定屏；随后按终端提示在系统设置中授权。'
echo ''
/bin/bash "$project_dir/双击安装.command" --prepare-permission-repair
/bin/bash "$project_dir/双击修复定屏权限.command" --combined
