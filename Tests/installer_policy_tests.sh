#!/bin/bash
# Portable policy/rollback tests. App metadata, signatures, launch and TCC are
# fixtures: this test never launches a Mac app or touches system permissions.
set -euo pipefail
test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$test_root/Installer/common.sh"
test_tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/DingPing.installer-tests.XXXXXX")"
trap '/bin/rm -rf "$test_tmp"' EXIT
DP_BUNDLE_ID=local.dingping.fixedsplit
DP_VERSION=0.4.0
DP_BUILD=6
DP_DIGEST=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
test_count=0

dp_plist() {
  /usr/bin/awk -F '=' -v key="$2" '$1==key {print substr($0,length(key)+2); found=1; exit} END {if(!found)exit 1}' "$1/Contents/Info.plist" 2>/dev/null
}
dp_signature_valid() { [[ -f "$1/.signature-valid" ]]; }
dp_running_pids() { if [[ -n "$test_pids" ]]; then printf '%s\n' "$test_pids"; else return 1; fi; }
dp_open_app() { test_launches=$((test_launches+1)); test_launched_path="$1"; }
dp_tcc_reset() { test_resets=$((test_resets+1)); test_reset_id="$1"; }
dp_archive_app() {
  test_archives=$((test_archives+1))
  [[ "$test_fail_archive" == 0 ]] || return 1
  /bin/cp -R "$1" "$2.snapshot" || return 1
  if [[ "$test_start_during_archive" == 1 ]]; then test_pids=999999; fi
}
dp_move() {
  if [[ "$1" == "$test_fail_move_from" ]]; then test_fail_move_from=''; return 1; fi
  if [[ "$1" == "$test_block_restore_from" ]]; then return 1; fi
  /bin/mv "$1" "$2" || return 1
  if [[ "$2" == "$test_corrupt_target" ]]; then /bin/rm -f "$2/.signature-valid"; fi
}
fail() { printf 'FAIL: case %s: %s\n' "$test_count" "$*" >&2; exit 1; }
expect_failure() { if "$@" > "$test_tmp/last-expected-error.txt" 2>&1; then fail "unexpected success: $*"; fi; }
new_case() {
  test_count=$((test_count+1))
  case_dir="$test_tmp/case $test_count"
  /bin/mkdir -p "$case_dir/user Applications" "$case_dir/.stage"
  target_app="$case_dir/user Applications/定屏.app"
  staged_app="$case_dir/.stage/定屏.app"
  archive="$case_dir/previous.zip"
  test_pids=''; test_launches=0; test_resets=0; test_archives=0
  test_launched_path=''; test_reset_id=''; test_fail_archive=0
  test_start_during_archive=0; test_fail_move_from=''
  test_block_restore_from=''; test_corrupt_target=''
  DP_SWAP_PENDING=0; DP_PRESERVE_STAGE=0
}
make_app() {
  local app="$1" version="${2:-0.4.0}" build="${3:-6}" identifier="${4:-local.dingping.fixedsplit}"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  printf 'CFBundleIdentifier=%s\nCFBundleShortVersionString=%s\nCFBundleVersion=%s\nCFBundleExecutable=DingPing\n' "$identifier" "$version" "$build" > "$app/Contents/Info.plist"
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/DingPing"
  /bin/chmod 755 "$app/Contents/MacOS/DingPing"
  printf '%s\n' "$DP_DIGEST" > "$app/Contents/Resources/source-digest.txt"
  : > "$app/.signature-valid"
}
expect_version() {
  local got
  got="$(dp_plist "$1" CFBundleShortVersionString || true)"
  [[ "$got" == "$2" ]] || fail "version $got, expected $2"
}
expect_no_actions() {
  [[ "$test_resets" == 0 && "$test_launches" == 0 ]] || fail 'unexpected TCC reset or launch'
}

new_case
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == build ]] || fail 'missing installation'
expect_no_actions

new_case
make_app "$target_app"
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == keep ]] || fail 'same release should be retained'
expect_no_actions

new_case
make_app "$target_app" 0.3.1 5
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == build ]] || fail 'old version must not reuse matching digest'
expect_failure dp_reset_current_permission "$target_app"
expect_failure dp_launch_current "$target_app"
expect_no_actions

new_case
make_app "$target_app" 0.4.0 5
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == build ]] || fail 'build must match'
expect_failure dp_reset_current_permission "$target_app"
expect_no_actions

new_case
make_app "$target_app"
printf 'wrong-digest\n' > "$target_app/Contents/Resources/source-digest.txt"
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == build ]] || fail 'content must match'
expect_failure dp_reset_current_permission "$target_app"
expect_no_actions

new_case
make_app "$target_app"
/bin/rm "$target_app/.signature-valid"
dp_choose_install "$target_app"
[[ "$DP_INSTALL_ACTION" == build ]] || fail 'invalid signature must not be reused'
expect_failure dp_reset_current_permission "$target_app"
expect_no_actions

new_case
make_app "$target_app" 0.4.0 6 example.unrelated.application
expect_failure dp_choose_install "$target_app"
expect_failure dp_reset_current_permission "$target_app"
expect_no_actions

new_case
make_app "$case_dir/outside.app"
/bin/ln -s "$case_dir/outside.app" "$target_app"
expect_failure dp_choose_install "$target_app"
expect_failure dp_reset_current_permission "$target_app"
expect_no_actions

new_case
make_app "$target_app"
test_pids=999999
expect_failure dp_choose_install "$target_app"
[[ -z "$DP_INSTALL_ACTION" ]] || fail 'running guard must precede same-version shortcut'
expect_failure dp_reset_current_permission "$target_app"
expect_failure dp_launch_current "$target_app"
expect_no_actions

new_case
make_app "$target_app" 0.4.1 1
expect_failure dp_choose_install "$target_app"
make_app "$target_app" 0.4.0 7
expect_failure dp_choose_install "$target_app"
make_app "$target_app" 0.10.0 1
expect_failure dp_choose_install "$target_app"
expect_no_actions

new_case
make_app "$target_app"
dp_reset_current_permission "$target_app"
[[ "$test_resets" == 1 && "$test_reset_id" == local.dingping.fixedsplit ]] || fail 'reset must be scoped to verified bundle'
dp_launch_current "$target_app"
[[ "$test_launches" == 1 && "$test_launched_path" == "$target_app" ]] || fail 'launch must use exact path including spaces'

new_case
expect_failure dp_reset_current_permission "$target_app"
expect_failure dp_launch_current "$target_app"
expect_no_actions

new_case
make_app "$target_app"
/bin/rm "$target_app/Contents/MacOS/DingPing"
expect_failure dp_reset_current_permission "$target_app"
expect_failure dp_launch_current "$target_app"
expect_no_actions

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
test_fail_archive=1
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
expect_version "$target_app" 0.3.1
[[ -d "$staged_app" && "$DP_SWAP_PENDING" == 0 ]] || fail 'archive failure changed apps'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
dp_replace_from_stage "$staged_app" "$target_app" "$archive"
dp_matches_release "$target_app" || fail 'successful replacement invalid'
expect_version "$archive.snapshot" 0.3.1
[[ "$DP_SWAP_PENDING" == 0 ]] || fail 'successful replacement left pending transaction'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
test_fail_move_from="$staged_app"
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
expect_version "$target_app" 0.3.1
[[ "$DP_SWAP_PENDING" == 0 && "$DP_PRESERVE_STAGE" == 0 ]] || fail 'rename failure not rolled back'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
test_corrupt_target="$target_app"
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
expect_version "$target_app" 0.3.1
[[ -d "$case_dir/.stage/rejected.app" && "$DP_SWAP_PENDING" == 0 ]] || fail 'post-install failure not rolled back'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
test_fail_move_from="$staged_app"
test_block_restore_from="$case_dir/.stage/previous.app"
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
[[ "$DP_PRESERVE_STAGE" == 1 && "$DP_SWAP_PENDING" == 1 ]] || fail 'rollback failure must preserve recovery files'
expect_version "$case_dir/.stage/previous.app" 0.3.1
expect_version "$archive.snapshot" 0.3.1

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app" 0.3.1 5
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
expect_version "$target_app" 0.3.1
[[ "$test_archives" == 0 ]] || fail 'invalid staging changed installation'

new_case
make_app "$staged_app"
test_corrupt_target="$target_app"
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
[[ ! -e "$target_app" && "$DP_SWAP_PENDING" == 0 ]] || fail 'invalid fresh install should not remain installed'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
test_start_during_archive=1
expect_failure dp_replace_from_stage "$staged_app" "$target_app" "$archive"
expect_version "$target_app" 0.3.1
[[ -d "$staged_app" && "$DP_SWAP_PENDING" == 0 ]] || fail 'app launched during archive was overwritten'

new_case
make_app "$target_app" 0.3.1 5
make_app "$staged_app"
DP_SWAP_TARGET="$target_app"; DP_SWAP_NEW="$staged_app"; DP_SWAP_OLD="$case_dir/.stage/previous.app"; DP_SWAP_PENDING=1
/bin/mv "$target_app" "$DP_SWAP_OLD"
/bin/mv "$staged_app" "$target_app"
dp_rollback > /dev/null
expect_version "$target_app" 0.3.1
[[ "$DP_SWAP_PENDING" == 0 ]] || fail 'exit-trap recovery incomplete'

printf 'PASS: %s installer policy and rollback scenarios; no real app launch, signing or permission reset.\n' "$test_count"
