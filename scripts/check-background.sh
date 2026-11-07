#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${XUXU_BUILD_DIR:-$project_dir/.build}"
swift build --package-path "$project_dir" --scratch-path "$build_dir"
test_dir="$(mktemp -d /private/tmp/mateo-background-check-XXXXXX)"
swiftc -parse-as-library -I "$build_dir/debug/Modules" \
 "$project_dir/Sources/FitnessApp/AppStore.swift" "$project_dir/Sources/FitnessApp/TrainingStore.swift" \
 "$project_dir/Sources/FitnessApp/CoachRequestStore.swift" "$project_dir/Sources/FitnessApp/PersonalAgentStore.swift" \
 "$project_dir/scripts/check-background.swift" "$build_dir"/debug/FitnessCore.build/*.swift.o -o "$test_dir/check"
XUXU_DATA_DIR="$test_dir/records" "$test_dir/check"
