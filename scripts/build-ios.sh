#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${XUXU_IOS_BUILD_DIR:-$PROJECT_ROOT/../../work/ios-build}"
# Documents may be managed by iCloud. Signing products there can acquire
# FinderInfo during the build, which codesign rejects. Keep final products local.
PRODUCTS_DIR="${XUXU_IOS_PRODUCTS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/xuxu-ios-products.XXXXXX")}"
DESTINATION="generic/platform=iOS"
if [[ -n "${XUXU_DEVICE_ID:-}" ]]; then
  DESTINATION="id=$XUXU_DEVICE_ID"
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "$PROJECT_ROOT/project.yml"
fi

xcodebuild -project "$PROJECT_ROOT/XuXu.xcodeproj" -scheme XuXu \
  -configuration Debug -destination "$DESTINATION" \
  -derivedDataPath "$BUILD_DIR" "CONFIGURATION_BUILD_DIR=$PRODUCTS_DIR" \
  -allowProvisioningUpdates build
codesign --verify --deep --strict "$PRODUCTS_DIR/XuXu.app"
printf '\nSigned app: %s\n' "$PRODUCTS_DIR/XuXu.app"

if [[ -n "${XUXU_DEVICE_ID:-}" ]]; then
  xcrun devicectl device install app --device "$XUXU_DEVICE_ID" \
    "$PRODUCTS_DIR/XuXu.app" --timeout 120
  printf '\nInstalled. First launch may require trusting your developer account on iPhone.\n'
fi
