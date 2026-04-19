#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${LUNGFISH_XCODE_PROJECT:-$ROOT_DIR/Lungfish.xcodeproj}"
SCHEME_NAME="${LUNGFISH_XCODE_SCHEME:-Lungfish}"
DESTINATION="${LUNGFISH_XCUI_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${LUNGFISH_XCUI_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-xcui}"
UI_TEST_TARGET="${LUNGFISH_XCUI_TARGET_NAME:-LungfishXCUITests}"

ONLY_TESTING_ARGS=()
if [ "$#" -gt 0 ]; then
  for identifier in "$@"; do
    ONLY_TESTING_ARGS+=("-only-testing:$identifier")
  done
fi

xcodebuild \
  build-for-testing \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${ONLY_TESTING_ARGS[@]}"

XCTESTRUN_FILE="$(find "$DERIVED_DATA_PATH/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
if [ -z "$XCTESTRUN_FILE" ]; then
  echo "No .xctestrun file was generated in $DERIVED_DATA_PATH/Build/Products" >&2
  exit 1
fi

PATCHED_XCTESTRUN_FILE="${XCTESTRUN_FILE%.xctestrun}.patched.xctestrun"
cp "$XCTESTRUN_FILE" "$PATCHED_XCTESTRUN_FILE"

UI_TARGET_APP_PATH="$(
  /usr/libexec/PlistBuddy \
    -c "Print :$UI_TEST_TARGET:DependentProductPaths:0" \
    "$PATCHED_XCTESTRUN_FILE"
)"

if [[ "$UI_TARGET_APP_PATH" != *.app ]]; then
  echo "Expected the first dependent product for $UI_TEST_TARGET to be an .app bundle, got: $UI_TARGET_APP_PATH" >&2
  exit 1
fi

# xcodebuild currently emits a bare target name for macOS UITargetAppPath in this project.
/usr/libexec/PlistBuddy -c "Delete :$UI_TEST_TARGET:UITargetAppPath" "$PATCHED_XCTESTRUN_FILE" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :$UI_TEST_TARGET:UITargetAppPath string $UI_TARGET_APP_PATH" "$PATCHED_XCTESTRUN_FILE"

xcodebuild \
  test-without-building \
  -xctestrun "$PATCHED_XCTESTRUN_FILE" \
  -destination "$DESTINATION" \
  "${ONLY_TESTING_ARGS[@]}"
