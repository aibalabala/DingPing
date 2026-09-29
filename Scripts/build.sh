#!/bin/bash
set -euo pipefail

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  echo "原生程序需要在 macOS 上编译。" >&2
  exit 1
fi
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "用法：build.sh 已存在的输出文件夹" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(cd "$1" && pwd)"
app_dir="$build_dir/定屏.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

echo "[1/4] 检查分区、拖动和自动归位规则"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$project_dir/Sources/Layout.c" "$project_dir/Tests/layout_tests.c" \
  -o "$build_dir/layout_tests"
"$build_dir/layout_tests"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$project_dir/Sources/DragPolicy.c" "$project_dir/Tests/drag_policy_tests.c" \
  -o "$build_dir/drag_policy_tests"
"$build_dir/drag_policy_tests"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$project_dir/Sources/PlacementPolicy.c" "$project_dir/Tests/placement_policy_tests.c" \
  -o "$build_dir/placement_policy_tests"
"$build_dir/placement_policy_tests"
/bin/bash "$project_dir/Tests/shell_messages_test.sh"

echo "[2/4] 编译当前 Mac 架构的原生程序"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
  -c "$project_dir/Sources/Layout.c" -o "$build_dir/Layout.o"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
  -c "$project_dir/Sources/DragPolicy.c" -o "$build_dir/DragPolicy.o"
/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
  -c "$project_dir/Sources/PlacementPolicy.c" -o "$build_dir/PlacementPolicy.o"
/usr/bin/xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Wno-unused-parameter \
  -Wno-deprecated-declarations -mmacosx-version-min=13.0 \
  -framework Cocoa -framework ApplicationServices -framework Carbon -framework CoreGraphics \
  "$project_dir/Sources/main.m" "$project_dir/Sources/WindowAccess.m" "$project_dir/Sources/DragGuard.m" "$project_dir/Sources/FocusObserver.m" \
  "$build_dir/Layout.o" "$build_dir/DragPolicy.o" "$build_dir/PlacementPolicy.o" \
  -o "$app_dir/Contents/MacOS/DingPing"

echo "[3/4] 生成应用包"
/bin/cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/bin/cp "$project_dir/使用说明.md" "$app_dir/Contents/Resources/使用说明.md"
/bin/bash "$project_dir/Scripts/source_digest.sh" > "$app_dir/Contents/Resources/source-digest.txt"
/bin/chmod 755 "$app_dir/Contents/MacOS/DingPing"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"

echo "[4/4] 本地签名与完整性检查"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
echo "应用已生成：$app_dir"
