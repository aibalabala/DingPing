#!/bin/bash
# Shared by the user-facing tools. Keep App inputs unchanged so a matching
# installation is never rebuilt just because the installer has been repaired.
# Compatible with the Bash 3.2 shipped with macOS.

dp_plist() {
  /usr/libexec/PlistBuddy -c "Print :${2}" "${1}/Contents/Info.plist" 2>/dev/null
}

dp_signature_valid() {
  /usr/bin/codesign --verify --deep --strict "${1}" >/dev/null 2>&1
}

dp_running_pids() {
  /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x DingPing
}

dp_open_app() {
  /usr/bin/open -n -a "${1}"
}

dp_tcc_reset() {
  /usr/bin/tccutil reset Accessibility "${1}"
}

dp_move() {
  /bin/mv "${1}" "${2}"
}

dp_archive_app() {
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${1}" "${2}" &&
    /usr/bin/unzip -tq "${2}" >/dev/null
}

dp_load_release() {
  local root="${1}"
  DP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${root}/Resources/Info.plist" 2>/dev/null)" || return 1
  DP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${root}/Resources/Info.plist" 2>/dev/null)" || return 1
  DP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${root}/Resources/Info.plist" 2>/dev/null)" || return 1
  DP_DIGEST="$(/bin/bash "${root}/Scripts/source_digest.sh")" || return 1
  [[ "${DP_BUNDLE_ID}" == local.dingping.fixedsplit && -n "${DP_VERSION}" && -n "${DP_BUILD}" && "${DP_DIGEST}" =~ ^[0-9a-f]{64}$ ]]
}

dp_show_app() {
  local app="${1}" version build identifier
  printf '位置：%s\n' "${app}"
  if [[ ! -e "${app}" && ! -L "${app}" ]]; then echo '状态：未安装'; return 0; fi
  version="$(dp_plist "${app}" CFBundleShortVersionString || true)"
  build="$(dp_plist "${app}" CFBundleVersion || true)"
  identifier="$(dp_plist "${app}" CFBundleIdentifier || true)"
  printf '版本：%s（构建 %s）\n应用标识：%s\n' "${version:-无法读取}" "${build:-无法读取}" "${identifier:-无法读取}"
}

dp_show_other_copy() {
  if [[ -e /Applications/定屏.app || -L /Applications/定屏.app ]]; then
    echo ''
    echo '注意：系统 Applications 文件夹里还有一个同名项目：'
    dp_show_app /Applications/定屏.app
    echo '本工具不会改动这份副本。授权时请使用上方个人 Applications 中的完整路径。'
  fi
}

dp_require_stopped() {
  local pids pid
  pids="$(dp_running_pids || true)"
  if [[ -z "${pids}" ]]; then return 0; fi
  echo '检测到定屏仍在运行。请从菜单栏选择「退出定屏」后重试；只关闭设置窗口不会退出。'
  for pid in ${pids}; do
    printf '进程 %s：' "${pid}"
    /bin/ps -ww -p "${pid}" -o command= 2>/dev/null || true
  done
  return 1
}

dp_replace_allowed() {
  local app="${1}" identifier
  if [[ -L "${app}" ]]; then
    echo '安装位置是符号链接，已停止，避免替换到其他位置。'
    return 1
  fi
  if [[ ! -e "${app}" ]]; then return 0; fi
  identifier="$(dp_plist "${app}" CFBundleIdentifier || true)"
  if [[ "${identifier}" != "${DP_BUNDLE_ID}" ]]; then
    printf '安装位置已有无法确认的同名项目，已停止：%s\n' "${app}"
    return 1
  fi
}

dp_installed_is_newer() {
  local app="${1}" version build
  version="$(dp_plist "${app}" CFBundleShortVersionString || true)"
  build="$(dp_plist "${app}" CFBundleVersion || true)"
  [[ "${version}" =~ ^[0-9]+(\.[0-9]+)*$ && "${build}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  /usr/bin/awk -v lhs="${version}" -v rhs="${DP_VERSION}" -v lb="${build}" -v rb="${DP_BUILD}" '
    function compare(a,b, i,n,m,x,y) {
      n=split(a,x,"."); m=split(b,y,"."); if(m>n)n=m;
      for(i=1;i<=n;i++) {if(x[i]+0>y[i]+0)return 1; if(x[i]+0<y[i]+0)return -1;}
      return 0;
    }
    BEGIN {c=compare(lhs,rhs); if(c==0)c=compare(lb,rb); exit(c>0?0:1);}'
}

dp_matches_release() {
  local app="${1}" value
  DP_MISMATCH=''
  if [[ ! -d "${app}" || -L "${app}" ]]; then DP_MISMATCH='没有找到完整的当前安装'; return 1; fi
  value="$(dp_plist "${app}" CFBundleIdentifier || true)"
  if [[ "${value}" != "${DP_BUNDLE_ID}" ]]; then DP_MISMATCH='应用标识不符'; return 1; fi
  value="$(dp_plist "${app}" CFBundleShortVersionString || true)"
  if [[ "${value}" != "${DP_VERSION}" ]]; then DP_MISMATCH="版本不符：${value:-未知}，需要 ${DP_VERSION}"; return 1; fi
  value="$(dp_plist "${app}" CFBundleVersion || true)"
  if [[ "${value}" != "${DP_BUILD}" ]]; then DP_MISMATCH="构建号不符：${value:-未知}，需要 ${DP_BUILD}"; return 1; fi
  value="$(dp_plist "${app}" CFBundleExecutable || true)"
  if [[ "${value}" != DingPing || ! -x "${app}/Contents/MacOS/DingPing" ]]; then DP_MISMATCH='主程序缺失或不可执行'; return 1; fi
  value="$(/bin/cat "${app}/Contents/Resources/source-digest.txt" 2>/dev/null || true)"
  if [[ "${value}" != "${DP_DIGEST}" ]]; then DP_MISMATCH='安装内容与本安装包不一致'; return 1; fi
  if ! dp_signature_valid "${app}"; then DP_MISMATCH='签名完整性检查未通过'; return 1; fi
}

dp_choose_install() {
  local app="${1}"
  DP_INSTALL_ACTION=''
  dp_require_stopped || return 1
  dp_replace_allowed "${app}" || return 1
  if dp_installed_is_newer "${app}"; then
    echo '已安装更高版本，已停止，避免旧安装包覆盖新版。'
    return 1
  fi
  if dp_matches_release "${app}"; then DP_INSTALL_ACTION=keep; else DP_INSTALL_ACTION=build; fi
}

dp_require_current() {
  local app="${1}"
  dp_require_stopped || return 1
  if ! dp_matches_release "${app}"; then
    printf '已停止：%s。\n' "${DP_MISMATCH}"
    echo '请先运行本包的「双击修复升级.command」，确认新版安装成功后再处理授权。'
    return 1
  fi
}

dp_reset_current_permission() {
  dp_require_current "${1}" || return 1
  # Never reset all applications, and never reset an unverified older copy.
  dp_tcc_reset "${DP_BUNDLE_ID}"
}

dp_launch_current() {
  dp_require_current "${1}" || return 1
  dp_open_app "${1}"
}

# A failed replacement is restored before temporary files may be removed.
# These variables also let the installer's EXIT trap recover an interrupted swap.
DP_SWAP_PENDING=0
DP_PRESERVE_STAGE=0
DP_SWAP_TARGET=''
DP_SWAP_NEW=''
DP_SWAP_OLD=''

dp_rollback() {
  [[ "${DP_SWAP_PENDING}" == 1 ]] || return 0
  if [[ -d "${DP_SWAP_OLD}" ]]; then
    if [[ -e "${DP_SWAP_TARGET}" ]]; then
      if ! dp_move "${DP_SWAP_TARGET}" "${DP_SWAP_OLD%/*}/rejected.app"; then
        DP_PRESERVE_STAGE=1; return 1
      fi
    fi
    if ! dp_move "${DP_SWAP_OLD}" "${DP_SWAP_TARGET}"; then
      DP_PRESERVE_STAGE=1; return 1
    fi
    echo '安装没有完成，原来的应用已恢复。'
  elif [[ ! -e "${DP_SWAP_NEW}" && -e "${DP_SWAP_TARGET}" ]]; then
    if ! dp_move "${DP_SWAP_TARGET}" "${DP_SWAP_OLD%/*}/rejected.app"; then
      DP_PRESERVE_STAGE=1; return 1
    fi
  fi
  DP_SWAP_PENDING=0
}

dp_replace_from_stage() {
  local new_app="${1}" target="${2}" archive="${3}"
  dp_require_stopped || return 1
  dp_replace_allowed "${target}" || return 1
  if ! dp_matches_release "${new_app}"; then
    printf '新应用校验失败：%s\n' "${DP_MISMATCH}"
    return 1
  fi
  if [[ -e "${target}" ]]; then
    dp_archive_app "${target}" "${archive}" || { echo '旧版备份失败，安装未替换。'; return 1; }
  fi
  # Check again after the archive operation, before changing either app.
  dp_require_stopped || return 1
  DP_SWAP_TARGET="${target}"
  DP_SWAP_NEW="${new_app}"
  DP_SWAP_OLD="${new_app%/*}/previous.app"
  DP_SWAP_PENDING=1
  if [[ -e "${target}" ]]; then
    if ! dp_move "${target}" "${DP_SWAP_OLD}"; then dp_rollback || true; return 1; fi
  fi
  if ! dp_move "${new_app}" "${target}"; then dp_rollback || true; return 1; fi
  if ! dp_matches_release "${target}"; then
    printf '替换后的应用校验失败：%s\n' "${DP_MISMATCH}"
    dp_rollback || true
    return 1
  fi
  DP_SWAP_PENDING=0
}
