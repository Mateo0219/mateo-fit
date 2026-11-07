#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${XUXU_BUILD_DIR:-$project_dir/.build}"
test_dir="$(mktemp -d /private/tmp/mateo-composer-events-XXXXXX)"
swiftc -parse-as-library -I "$build_dir/debug/Modules" \
 "$project_dir/Sources/FitnessApp/CoachComposerDraft.swift" "$project_dir/scripts/check-composer-events.swift" \
 "$build_dir"/debug/FitnessCore.build/*.swift.o -o "$test_dir/check"
if "$test_dir/check" --legacy; then
 echo 'Regression did not catch stale text events'; exit 1
else
 code=$?; [[ "$code" == 2 ]] || exit "$code"
fi
"$test_dir/check"
