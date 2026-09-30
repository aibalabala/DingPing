#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# Relative names make an unchanged package independent of its extraction folder.
/usr/bin/shasum -a 256 Sources/*.c Sources/*.h Sources/*.m Resources/Info.plist \
  Scripts/*.sh Tests/*.c Tests/*.m Installer/repair_accessibility.command 使用说明.md | \
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
