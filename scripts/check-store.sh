#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${XUXU_BUILD_DIR:-$project_dir/.build}"
swift build --package-path "$project_dir" --scratch-path "$build_dir"
module_dir="$build_dir/debug"
test_dir="$(mktemp -d /private/tmp/mateo-store-check-XXXXXX)"
swiftc -parse-as-library -I "$module_dir/Modules" \
  "$project_dir/Sources/FitnessApp/AppStore.swift" "$project_dir/Sources/FitnessApp/TrainingStore.swift" "$project_dir/Sources/FitnessApp/CoachRequestStore.swift" "$project_dir/Sources/FitnessApp/PersonalAgentStore.swift" "$project_dir/scripts/check-store.swift" \
  "$module_dir"/FitnessCore.build/*.swift.o \
  -o "$test_dir/check-store"
XUXU_DATA_DIR="$test_dir/records" "$test_dir/check-store"
printf '\nSynthetic test artifacts: %s\n' "$test_dir"
