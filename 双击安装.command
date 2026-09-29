#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare_repair=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --prepare-permission-repair ]]; then prepare_repair=1; else echo '不支持的安装参数。'; exit 2; fi
fi
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上运行这个安装脚本。'; exit 1; fi
source "$project_dir/Installer/common.sh"

log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/安装日志.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1
build_dir=''
stage_dir=''
lock_dir="$log_dir/安装进行中"
lock_owned=0
finish() {
  local result=$?
  trap - EXIT
  if ! dp_rollback; then
    result=1
    printf '自动恢复失败，保留现场：%s\n' "$stage_dir"
    printf '旧应用：%s\n' "$DP_SWAP_OLD"
  fi
  if [[ -n "$build_dir" && -d "$build_dir" ]]; then /bin/rm -rf "$build_dir"; fi
  if [[ -n "$stage_dir" && -d "$stage_dir" && "$DP_PRESERVE_STAGE" == 0 ]]; then /bin/rm -rf "$stage_dir"; fi
  if [[ "$lock_owned" == 1 ]]; then /bin/rm -f "$lock_dir/pid"; /bin/rmdir "$lock_dir" || true; fi
  if [[ $result -ne 0 ]]; then printf '\n安装流程未完成。日志：%s\n' "$log_file"; fi
  if [[ "$prepare_repair" == 0 && -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
  echo '另一个安装流程可能仍在进行，已停止，避免同时替换应用。'
  printf '安装锁：%s\n' "$lock_dir"
  echo '若之前的终端意外关闭，请确认没有安装脚本运行，再移除该文件夹后重试。'
  exit 1
fi
lock_owned=1
printf '%s\n' "$$" > "$lock_dir/pid"
dp_load_release "$project_dir" || { echo '安装包信息无法读取，请重新完整解压。'; exit 1; }
echo '定屏 · 安装与升级修正版 1'
printf '本包应用：%s（构建 %s）\n' "$DP_VERSION" "$DP_BUILD"
install_root="$HOME/Applications"
target_app="$install_root/定屏.app"
echo ''
echo '当前安装：'
dp_show_app "$target_app"
dp_show_other_copy
/usr/bin/sw_vers
mac_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [[ "$mac_major" -lt 13 ]]; then echo '此版本要求 macOS 13 或更新版本。'; exit 1; fi

# Even the unchanged-version path must first reject an old running copy.
dp_choose_install "$target_app" || exit 1
if [[ "$DP_INSTALL_ACTION" == keep ]]; then
  echo '已确认版本、构建号、内容指纹和签名一致：保留现有 App，不重复编译或签名。'
else
  printf '需要安装当前版本：%s。\n' "$DP_MISMATCH"
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
    echo '需要先安装 Apple Command Line Tools（无需完整 Xcode）。'
    /usr/bin/xcode-select --install || true
    echo '完成系统安装后，再重新双击本工具。当前尚未安装新版，未重置授权。'
    exit 3
  fi
  build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/DingPing.build.XXXXXX")"
  /bin/bash "$project_dir/Tests/installer_policy_tests.sh"
  /bin/bash "$project_dir/Scripts/build.sh" "$build_dir"
  dp_require_stopped || exit 1
  /bin/mkdir -p "$install_root"
  stage_dir="$(/usr/bin/mktemp -d "$install_root/.DingPing.install.XXXXXX")"
  /usr/bin/ditto "$build_dir/定屏.app" "$stage_dir/定屏.app"
  archive=''
  if [[ -e "$target_app" ]]; then
    backup_root="$HOME/Library/Application Support/定屏/Backups"
    /bin/mkdir -p "$backup_root"
    backup_dir="$(/usr/bin/mktemp -d "$backup_root/update.XXXXXX")"
    archive="$backup_dir/previous.zip"
  fi
  dp_replace_from_stage "$stage_dir/定屏.app" "$target_app" "$archive" || exit 1
  if [[ -n "$archive" ]]; then printf '旧版已压缩备份：%s\n' "$archive"; fi
fi

echo ''
echo '已确认安装成功：'
dp_show_app "$target_app"
echo 'Finder 侧栏的「应用程序」可能指向 /Applications；本程序安装在个人 Applications。'
echo '系统列表中的名称仍然是「定屏」，不会因升级增加一个带版本号的条目。'
printf '日常使用直接打开 %s；无需反复运行安装脚本。\n' "${target_app}"
if [[ "$prepare_repair" == 1 ]]; then
  echo '应用保持退出，接下来只为这份已验证的 App 修复授权。'
else
  /usr/bin/open -R "$target_app" >/dev/null 2>&1 || true
  dp_launch_current "$target_app" || { echo '已安装，但未能启动。请按上方完整路径打开。'; exit 1; }
  echo '首次使用默认自由模式。授权后点任一布局即可自动分屏。'
  echo '若系统开关已开启但仍未授权，请先退出定屏，再运行「双击修复升级.command」。'
fi
