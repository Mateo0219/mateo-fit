#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${XUXU_BUILD_DIR:-$project_dir/.build}"
app_path="${XUXU_APP_PATH:-$project_dir/../Mateo Fit.app}"
swift build -c release --package-path "$project_dir" --scratch-path "$build_dir"
"$build_dir/release/CoreChecks"
python3 "$project_dir/scripts/package_mac.py" "$build_dir/release/XuXuDesktop" "$app_path"
