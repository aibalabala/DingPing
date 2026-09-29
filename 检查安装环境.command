#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "请在 Mac 上运行。"; exit 1; fi
report="$HOME/Desktop/定屏诊断结果.txt"
exec > >(/usr/bin/tee "$report") 2>&1
temp_dir=""
finish() {
  result=$?
  trap - EXIT
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then /bin/rm -rf "$temp_dir"; fi
  echo ""
  echo "诊断退出码：$result"
  echo "结果已保存：$report"
  if [[ -t 0 ]]; then read -r -p "按回车关闭…" _answer || true; fi
  exit "$result"
}
trap finish EXIT
echo "定屏 v0.5.2 安装环境诊断"
/usr/bin/sw_vers
/usr/bin/uname -m
/usr/bin/xcode-select -p
/usr/bin/xcrun clang --version
temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/DingPing.check.XXXXXX")"
/bin/bash "$project_dir/Scripts/build.sh" "$temp_dir"
echo "本机编译、分区测试、应用包检查已通过。此脚本不会安装或启动程序。"
