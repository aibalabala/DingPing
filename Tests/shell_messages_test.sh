#!/bin/bash
# Runs only the two real display statements. Never installs, signs or resets permissions.
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_line="$(/usr/bin/awk '/^printf .*日常使用直接打开/ {print; count++} END {if(count!=1)exit 1}' "${task_root}/双击安装.command")"
repair_line="$(/usr/bin/awk '/^printf .*这个工具只重置定屏/ {print; count++} END {if(count!=1)exit 1}' "${task_root}/双击修复定屏权限.command")"
task_bash="${BASH:-/bin/bash}"
target_app='/Users/test user/Applications/定屏.app'
bundle_id='local.dingping.fixedsplit'
export target_app bundle_id

# Execute the exact statements from the deliverable, rather than copied variants.
# C, installed UTF-8 locales and the caller's current locale cover string output.
task_utf8_locale="$(/usr/bin/locale -a | /usr/bin/awk 'tolower($0) ~ /utf-?8/ && !found {print; found=1}')"
for task_locale in CURRENT C ${task_utf8_locale}; do
  if [[ "${task_locale}" == CURRENT ]]; then
    install_output="$("${task_bash}" -u -c "${install_line}")"
    repair_output="$("${task_bash}" -u -c "${repair_line}")"
  else
    install_output="$(LC_ALL="${task_locale}" "${task_bash}" -u -c "${install_line}")"
    repair_output="$(LC_ALL="${task_locale}" "${task_bash}" -u -c "${repair_line}")"
  fi
  [[ "${install_output}" == "日常使用直接打开 ${target_app}；无需反复运行安装脚本。" ]]
  [[ "${repair_output}" == "这个工具只重置定屏（${bundle_id}）的辅助功能授权。" ]]
  printf 'PASS: display statements under %s\n' "${task_locale}"
done
printf '%s\n' 'PASS: actual display statements preserve Chinese punctuation and spaces; no install or permission reset performed.'
