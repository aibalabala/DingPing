#!/bin/bash
# The prebuilt App is kept in an install-only folder inside the GitHub DMG.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then echo '请在 Mac 上运行。'; exit 1; fi
if [[ "$(/usr/bin/uname -m)" != arm64 ]]; then echo '此 DMG 适用于 Apple Silicon Mac。'; exit 1; fi

dmg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$dmg_dir/.dingping-install.sh" && -f "$dmg_dir/../.dingping-install.sh" ]]; then
  dmg_dir="$(cd "$dmg_dir/.." && pwd)"
fi
if [[ ! -f "$dmg_dir/.dingping-install.sh" ]]; then echo 'DMG 缺少安装组件，请重新下载完整映像。'; exit 1; fi
source "$dmg_dir/.dingping-install.sh"
DP_BUNDLE_ID=local.dingping.fixedsplit
source_app="$dmg_dir/.安装资源/定屏.app"
install_root="$HOME/Applications"
target_app="$install_root/定屏.app"
log_dir="$HOME/Library/Logs/定屏"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/DMG安装日志.txt"
exec > >(/usr/bin/tee "$log_file") 2>&1

stage_dir=''
swap_pending=0
keep_stage=0
had_previous=0
lock_dir="$log_dir/安装进行中"
lock_owned=0
finish() {
  local result=$?
  trap - EXIT
  if [[ "$swap_pending" == 1 && -n "$stage_dir" && -d "$stage_dir/previous.app" ]]; then
    if [[ -e "$target_app" ]]; then
      if ! /bin/mv "$target_app" "$stage_dir/rejected.app"; then keep_stage=1; result=1; fi
    fi
    if [[ ! -e "$target_app" ]]; then
      if ! /bin/mv "$stage_dir/previous.app" "$target_app"; then keep_stage=1; result=1; fi
    fi
    if [[ -e "$target_app" ]]; then echo '安装未完成，已尝试恢复原来的应用。'; fi
  fi
  if [[ "$swap_pending" == 1 && "$had_previous" == 0 && -n "$stage_dir" && ! -d "$stage_dir/previous.app" && -e "$target_app" ]]; then
    /bin/mv "$target_app" "$stage_dir/rejected.app" || { keep_stage=1; result=1; }
  fi
  if [[ -n "$stage_dir" && -d "$stage_dir" && "$keep_stage" == 0 ]]; then /bin/rm -rf "$stage_dir"; fi
  if [[ "$lock_owned" == 1 ]]; then /bin/rm -f "$lock_dir/pid"; /bin/rmdir "$lock_dir" || true; fi
  if [[ $result -ne 0 ]]; then
    printf '\n安装未完成。日志：%s\n' "$log_file"
    if [[ "$keep_stage" == 1 ]]; then printf '保留恢复现场：%s\n' "$stage_dir"; fi
  fi
  if [[ -t 0 ]]; then read -r -p '按回车关闭此窗口…' _answer || true; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

app_field() {
  /usr/libexec/PlistBuddy -c "Print :${2}" "$1/Contents/Info.plist" 2>/dev/null
}
cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}'
}
require_stopped() {
  local pids
  pids="$(/usr/bin/pgrep -u "$(/usr/bin/id -u)" -x DingPing || true)"
  if [[ -z "$pids" ]]; then return 0; fi
  echo '定屏仍在运行。请先从菜单栏定屏图标选择「退出定屏」，再重新双击安装。'
  while read -r pid; do /bin/ps -ww -p "$pid" -o pid= -o command= 2>/dev/null || true; done <<< "$pids"
  return 1
}

echo '定屏 · GitHub 预编译 DMG 安装'
printf '安装位置：%s\n' "$target_app"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
  echo '另一个安装流程可能正在运行；本次安装已停止。'
  exit 1
fi
lock_owned=1
printf '%s\n' "$$" > "$lock_dir/pid"

if [[ ! -d "$source_app" || -L "$source_app" ]]; then echo 'DMG 安装资源中找不到定屏.app。请重新下载完整映像。'; exit 1; fi
if [[ "$(app_field "$source_app" CFBundleIdentifier)" != local.dingping.fixedsplit ]]; then echo 'DMG 应用标识不正确。'; exit 1; fi
if [[ ! -x "$source_app/Contents/MacOS/DingPing" ]] || ! /usr/bin/codesign --verify --deep --strict "$source_app" >/dev/null 2>&1; then
  echo 'DMG 应用完整性检查失败。请重新下载原始文件。'
  exit 1
fi
version="$(app_field "$source_app" CFBundleShortVersionString)"
build="$(app_field "$source_app" CFBundleVersion)"
source_hash="$(cdhash "$source_app")"
if [[ -z "$version" || -z "$build" || -z "$source_hash" ]]; then echo 'DMG 应用版本或签名无法读取。'; exit 1; fi
printf 'DMG 应用版本：%s（构建 %s）\n' "$version" "$build"
DP_VERSION="$version"
DP_BUILD="$build"
dp_request_quit
require_stopped

previous_hash=''
other_same_id=0
if [[ -L /Applications/定屏.app ]]; then
  echo '系统 Applications 中的同名项目是符号链接，已停止以免误删。请先在 Finder 中核对并移除后重试。'
  exit 1
fi
if [[ -d /Applications/定屏.app && ! -L /Applications/定屏.app &&
      "$(app_field /Applications/定屏.app CFBundleIdentifier || true)" == local.dingping.fixedsplit ]]; then
  other_same_id=1
  printf '另外发现同标识的应用：/Applications/定屏.app（版本 %s）。\n' \
    "$(app_field /Applications/定屏.app CFBundleShortVersionString || true)"
  echo '新版安装成功后会把这个旧副本移到废纸篓。'
fi
if [[ -L "$target_app" ]]; then echo '安装位置是符号链接，已停止。'; exit 1; fi
if [[ -e "$target_app" ]]; then
  if [[ "$(app_field "$target_app" CFBundleIdentifier || true)" != local.dingping.fixedsplit ]]; then
    echo '个人 Applications 中已有其他同名项目，已停止以免覆盖。'
    exit 1
  fi
  if dp_installed_is_newer "$target_app"; then
    echo '已安装更高版本；这个旧 DMG 不会降级覆盖它。'
    exit 1
  fi
  previous_hash="$(cdhash "$target_app" || true)"
  if /usr/bin/codesign --verify --deep --strict "$target_app" >/dev/null 2>&1 &&
     [[ "$(app_field "$target_app" CFBundleShortVersionString || true)" == "$version" &&
        "$(app_field "$target_app" CFBundleVersion || true)" == "$build" &&
        "$(cdhash "$target_app")" == "$source_hash" ]]; then
    installed_same=1
  fi
fi

if [[ "${installed_same:-0}" == 1 ]]; then
  echo '相同构建和签名已经安装，保留现有 App。'
else
  /bin/mkdir -p "$install_root"
  stage_dir="$(/usr/bin/mktemp -d "$install_root/.DingPing.dmg.XXXXXX")"
  /usr/bin/ditto "$source_app" "$stage_dir/new.app"
  /usr/bin/codesign --verify --deep --strict "$stage_dir/new.app"
  if [[ "$(cdhash "$stage_dir/new.app")" != "$source_hash" ]]; then echo '复制后的签名不匹配，已停止。'; exit 1; fi

  if [[ -e "$target_app" ]]; then
    backup_root="$HOME/Library/Application Support/定屏/Backups"
    /bin/mkdir -p "$backup_root"
    backup_dir="$(/usr/bin/mktemp -d "$backup_root/dmg.XXXXXX")"
    backup_zip="$backup_dir/previous.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$target_app" "$backup_zip"
    /usr/bin/unzip -tq "$backup_zip" >/dev/null
    printf '旧应用压缩备份：%s\n' "$backup_zip"
  fi
  require_stopped

  swap_pending=1
  if [[ -e "$target_app" ]]; then had_previous=1; /bin/mv "$target_app" "$stage_dir/previous.app"; fi
  /bin/mv "$stage_dir/new.app" "$target_app"
  /usr/bin/codesign --verify --deep --strict "$target_app"
  if [[ "$(cdhash "$target_app")" != "$source_hash" ]]; then echo '替换后签名不匹配。'; exit 1; fi
  swap_pending=0
fi
printf '\n安装完成：%s\n' "$target_app"
if [[ "$other_same_id" == 1 ]]; then
  dp_trash_legacy_copy /Applications/定屏.app "$target_app" "$HOME/.Trash" || exit 1
fi
echo '首次分屏请在「系统设置 → 隐私与安全性 → 辅助功能」添加上面的准确路径并打开开关。'
/usr/bin/open -R "$target_app" >/dev/null 2>&1 || true
needs_repair=0
if [[ -n "$previous_hash" && "$previous_hash" != "$source_hash" ]]; then needs_repair=1; fi
if [[ "$other_same_id" == 1 ]]; then needs_repair=1; fi
if [[ "$needs_repair" == 1 ]]; then
  echo '检测到旧签名或同标识副本。旧版的辅助功能开关不能代表新版已获授权。'
  if [[ -t 0 && -f "$dmg_dir/高级安装/双击修复定屏授权.command" ]]; then
    if /bin/bash "$dmg_dir/高级安装/双击修复定屏授权.command" --from-installer; then
      echo '授权引导已完成；请以新应用内的「权限诊断」为准。'
    else
      echo '应用已经安装，授权引导尚未完成。稍后可双击 DMG 里的「双击修复定屏授权.command」。'
    fi
  else
    echo '请双击 DMG 中的「双击修复定屏授权.command」重新添加当前 App。'
  fi
else
  /usr/bin/open -n -a "$target_app"
  echo '如果系统显示旧开关已开但仍未授权，请用 DMG 里的「双击修复定屏授权.command」。'
fi
