#!/usr/bin/env bash
# ATTENDED DIAGNOSTIC, not a release gate: macOS ties the UI-automation (TCC)
# permission to the freshly built XCUITests-Runner binary, so any rebuild can
# re-prompt; unattended runs then fail with "Timed out while enabling
# automation mode". Run this with an operator at the keyboard.
#
# If a run hangs or times out while xcodebuild is "enabling automation mode",
# a macOS permission prompt is waiting for you (or a prior grant was dropped
# after a rebuild, since the TCC grant is tied to the specific signed binary).
# Bring the prompt to the foreground and approve it, or re-grant manually in
# System Settings > Privacy & Security > Automation (and, if needed,
# Accessibility) for the LungfishXCUITests-Runner / Lungfish app, then re-run
# this script.
#
# Most of the 34 XCUI robots predate the 2026-07-07 workflow-enablement menu
# redesign (commit 69bf2e72) and needed repair; see build/xcui-triage-report.md
# for the full per-test disposition (repair/delete/defer + rationale).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${LUNGFISH_XCODE_PROJECT:-$ROOT_DIR/Lungfish.xcodeproj}"
SCHEME_NAME="${LUNGFISH_XCODE_SCHEME:-Lungfish}"
DESTINATION="${LUNGFISH_XCUI_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${LUNGFISH_XCUI_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-xcui}"
UI_TEST_TARGET="${LUNGFISH_XCUI_TARGET_NAME:-LungfishXCUITests}"

# --smoke: run only the diagnostic tier's core -- the boot/reachability robots
# that were green in the 2026-08-22 triage (build/xcui-final2.log) and do not
# depend on the Tools-menu redesign follow-up work. Keep this list in sync
# with build/xcui-triage-report.md's disposition table; it is meant to answer
# "is the app fundamentally launchable and automatable right now?" quickly,
# not to replace the full 34-test run.
SMOKE_TEST_IDENTIFIERS=(
  "LungfishXCUITests/BundleBrowserXCUITests/testOpeningReferenceBundleShowsBrowserAndPreservesSelection"
  "LungfishXCUITests/DatabaseSearchXCUITests/testDeterministicSearchChangesPrimaryActionToDownloadSelectedAfterSelection"
  "LungfishXCUITests/DatabaseSearchXCUITests/testOpeningNCBISearchThroughToolsMenuShowsUnifiedSearchDialog"
  "LungfishXCUITests/DatabaseSearchXCUITests/testOpeningPathoplexusRequiresConsentBeforeSearchActionsAreEnabled"
  "LungfishXCUITests/DatabaseSearchXCUITests/testSwitchingDestinationsPreservesEnteredQueryText"
  "LungfishXCUITests/MainWindowNavigationXCUITests/testOperationsPanelFailedOperationOpensPrefilledGitHubIssueWithoutNetwork"
  "LungfishXCUITests/MainWindowNavigationXCUITests/testToolbarAndAnalysesGroupAreReachableByPointerAndKeyboard"
  "LungfishXCUITests/PrimerTrimXCUITests/testInspectorExposesPrimerTrimButtonAndOpensDialog"
  "LungfishXCUITests/PrimerTrimXCUITests/testRunButtonProducesNewAlignmentTrack"
  "LungfishXCUITests/ProjectLifecycleXCUITests/testUITestProjectPathLaunchOpensProjectWithoutWelcome"
  "LungfishXCUITests/ProjectLifecycleXCUITests/testWelcomeCreateProjectLogsRequestAndCreatesInjectedProject"
  "LungfishXCUITests/ProjectLifecycleXCUITests/testWelcomeOpenProjectLogsRequestAndOpensInjectedProject"
)

SMOKE_MODE=0
POSITIONAL_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--smoke" ]; then
    SMOKE_MODE=1
  else
    POSITIONAL_ARGS+=("$arg")
  fi
done

ONLY_TESTING_ARGS=()
if [ "$SMOKE_MODE" = "1" ]; then
  if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
    echo "warning: --smoke ignores explicit test identifiers; running the smoke tier only" >&2
  fi
  for identifier in "${SMOKE_TEST_IDENTIFIERS[@]}"; do
    ONLY_TESTING_ARGS+=("-only-testing:$identifier")
  done
elif [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
  for identifier in "${POSITIONAL_ARGS[@]}"; do
    ONLY_TESTING_ARGS+=("-only-testing:$identifier")
  done
fi

if [ "${LUNGFISH_XCUI_SKIP_CLI_BUILD:-0}" != "1" ]; then
  swift build --package-path "$ROOT_DIR" --product lungfish-cli
fi

# Resolve the lungfish-cli binary path once, here, from the same SwiftPM
# invocation the build step above just used -- rather than letting the test
# process re-derive it later by shelling out to `swift build --show-bin-path`
# on its own (see LungfishFixtureCatalog.swiftPMBinPath). Shelling out from
# inside the XCUITest host process is fragile: it depends on that process
# inheriting a working PATH/environment under xcodebuild's automation
# session, and can race the `.build/.lock` SwiftPM holds during the build
# step above. Resolving it here and threading it through the xctestrun's
# test-host EnvironmentVariables is the robust fix.
LUNGFISH_CLI_BIN_PATH="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/lungfish-cli"
if [ ! -x "$LUNGFISH_CLI_BIN_PATH" ]; then
  echo "warning: resolved lungfish-cli path is not executable: $LUNGFISH_CLI_BIN_PATH" >&2
  LUNGFISH_CLI_BIN_PATH=""
fi

BUILD_FOR_TESTING_CMD=(
  xcodebuild
  build-for-testing \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH"
)
if [ "${#ONLY_TESTING_ARGS[@]}" -gt 0 ]; then
  BUILD_FOR_TESTING_CMD+=("${ONLY_TESTING_ARGS[@]}")
fi
"${BUILD_FOR_TESTING_CMD[@]}"

find "$DERIVED_DATA_PATH/Build/Products" -maxdepth 1 -name '*.patched*.xctestrun' -delete

XCTESTRUN_FILE="$(find "$DERIVED_DATA_PATH/Build/Products" -maxdepth 1 -name '*.xctestrun' ! -name '*.patched*.xctestrun' -print -quit)"
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

# Thread the resolved lungfish-cli path into the LungfishXCUITests host
# process's own environment (distinct from UITargetAppEnvironmentVariables,
# which only affects the app under test). LungfishFixtureCatalog.cliBinaryURL
# reads LUNGFISH_CLI_PATH first and only falls back to shelling out to `swift
# build --show-bin-path` when it is unset, so this makes fixture builders
# (e.g. LungfishProjectFixtureBuilder.makeAlignmentTreeBundleProject, which
# shells out to lungfish-cli directly to author .lungfishmsa/.lungfishtree
# fixtures) resolve the binary deterministically instead of re-deriving it.
if [ -n "$LUNGFISH_CLI_BIN_PATH" ]; then
  /usr/libexec/PlistBuddy -c "Delete :$UI_TEST_TARGET:EnvironmentVariables:LUNGFISH_CLI_PATH" "$PATCHED_XCTESTRUN_FILE" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$UI_TEST_TARGET:EnvironmentVariables:LUNGFISH_CLI_PATH string $LUNGFISH_CLI_BIN_PATH" "$PATCHED_XCTESTRUN_FILE"
fi

TEST_WITHOUT_BUILDING_CMD=(
  xcodebuild
  test-without-building \
  -xctestrun "$PATCHED_XCTESTRUN_FILE" \
  -destination "$DESTINATION"
)
if [ "${#ONLY_TESTING_ARGS[@]}" -gt 0 ]; then
  TEST_WITHOUT_BUILDING_CMD+=("${ONLY_TESTING_ARGS[@]}")
fi
"${TEST_WITHOUT_BUILDING_CMD[@]}"
