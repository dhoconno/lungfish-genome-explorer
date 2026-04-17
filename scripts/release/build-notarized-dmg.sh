#!/bin/bash
#
# build-notarized-dmg.sh
#
# Create a clean Apple Silicon Lungfish release archive, embed the CLI inside the
# app bundle, notarize the app, wrap it in a DMG, notarize the DMG, and record
# release metadata for reproducibility.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-notarized-dmg.sh --signing-identity "Developer ID Application: Example (TEAMID)" --team-id TEAMID --notary-profile PROFILE [--scratch-path PATH] [--archive-path PATH] [--release-dir PATH] [--derived-data-path PATH]

Required:
  --signing-identity  Developer ID Application identity used for codesign
  --team-id           Apple Developer Team ID
  --notary-profile    Keychain profile configured for xcrun notarytool

Optional:
  --scratch-path      SwiftPM scratch path for lungfish-cli build (default: .build/xcode-cli-release)
  --archive-path      Archive output path (default: build/Release/Lungfish.xcarchive)
  --release-dir       Release directory (default: build/Release)
  --derived-data-path DerivedData path for the Xcode archive (default: <project-root>/.build/release-derived-data)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SIGNING_IDENTITY=""
TEAM_ID=""
NOTARY_PROFILE=""
SCRATCH_PATH="${PROJECT_ROOT}/.build/xcode-cli-release"
RELEASE_DIR="${PROJECT_ROOT}/build/Release"
ARCHIVE_PATH="${RELEASE_DIR}/Lungfish.xcarchive"
DERIVED_DATA_PATH=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --signing-identity)
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --scratch-path)
            SCRATCH_PATH="$2"
            shift 2
            ;;
        --archive-path)
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --release-dir)
            RELEASE_DIR="$2"
            shift 2
            ;;
        --derived-data-path)
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$SIGNING_IDENTITY" ] || [ -z "$TEAM_ID" ] || [ -z "$NOTARY_PROFILE" ]; then
    usage >&2
    exit 64
fi

if [ -z "$DERIVED_DATA_PATH" ]; then
    DERIVED_DATA_PATH="${PROJECT_ROOT}/.build/release-derived-data"
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 69
    fi
}

require_command rg

for command in xcodebuild xcrun swift codesign hdiutil ditto shasum mktemp /usr/libexec/PlistBuddy; do
    require_command "$command"
done

if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    echo "signing identity not found in keychain: $SIGNING_IDENTITY" >&2
    exit 70
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool keychain profile is not usable: $NOTARY_PROFILE" >&2
    exit 70
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Lungfish.app"
RELEASE_APP_PATH="${RELEASE_DIR}/Lungfish.app"
METADATA_PATH="${RELEASE_DIR}/release-metadata.txt"
APP_NOTARY_LOG="${RELEASE_DIR}/notary-app-log.json"
DMG_NOTARY_LOG="${RELEASE_DIR}/notary-dmg-log.json"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
mkdir -p "$(dirname "$DERIVED_DATA_PATH")"

cd "$PROJECT_ROOT"

resolved_build_timestamp() {
    if [ -n "${LUNGFISH_BUILD_TIMESTAMP:-}" ]; then
        /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LUNGFISH_BUILD_TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null
        printf '%s\n' "$LUNGFISH_BUILD_TIMESTAMP"
        return
    fi

    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        /bin/date -u -r "$SOURCE_DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ"
        return
    fi

    /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [ -n "${SOURCE_DATE_EPOCH:-}" ] && [ -z "${LUNGFISH_BUILD_TIMESTAMP:-}" ]; then
    LUNGFISH_BUILD_TIMESTAMP="$(resolved_build_timestamp)"
    export LUNGFISH_BUILD_TIMESTAMP
fi

SWIFT_BUILD_PREFIX_MAP_ARGS=(
    -Xswiftc -debug-prefix-map
    -Xswiftc "$SCRATCH_PATH=/swiftpm-build"
    -Xswiftc -debug-prefix-map
    -Xswiftc "$PROJECT_ROOT=/workspace"
    -Xswiftc -file-compilation-dir
    -Xswiftc /workspace
    -Xcc "-ffile-prefix-map=$SCRATCH_PATH=/swiftpm-build"
    -Xcc "-fdebug-prefix-map=$SCRATCH_PATH=/swiftpm-build"
    -Xcc "-ffile-prefix-map=$PROJECT_ROOT=/workspace"
    -Xcc "-fdebug-prefix-map=$PROJECT_ROOT=/workspace"
)

XCODE_OTHER_SWIFT_FLAGS="-debug-prefix-map $SCRATCH_PATH=/swiftpm-build -debug-prefix-map $PROJECT_ROOT=/workspace -file-compilation-dir /workspace"
XCODE_OTHER_CFLAGS="-ffile-prefix-map=$SCRATCH_PATH=/swiftpm-build -fdebug-prefix-map=$SCRATCH_PATH=/swiftpm-build -ffile-prefix-map=$PROJECT_ROOT=/workspace -fdebug-prefix-map=$PROJECT_ROOT=/workspace"

LUNGFISH_SKIP_EMBED_LUNGFISH_CLI=1 \
LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS=1 \
xcodebuild -project Lungfish.xcodeproj \
    -scheme Lungfish \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    EXCLUDED_ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=YES \
    OTHER_SWIFT_FLAGS="\$(inherited) $XCODE_OTHER_SWIFT_FLAGS" \
    OTHER_CFLAGS="\$(inherited) $XCODE_OTHER_CFLAGS" \
    OTHER_CPLUSPLUSFLAGS="\$(inherited) $XCODE_OTHER_CFLAGS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive

if [ ! -d "$APP_PATH" ]; then
    echo "archived app not found: $APP_PATH" >&2
    exit 72
fi

/usr/bin/xcrun swift build \
    --package-path "$PROJECT_ROOT" \
    --product lungfish-cli \
    --configuration release \
    --arch arm64 \
    --scratch-path "$SCRATCH_PATH" \
    "${SWIFT_BUILD_PREFIX_MAP_ARGS[@]}"

CLI_SOURCE="${SCRATCH_PATH}/arm64-apple-macosx/release/lungfish-cli"
CLI_DEST="${APP_PATH}/Contents/MacOS/lungfish-cli"
WORKFLOW_TOOLS_DIR="${APP_PATH}/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"

if [ ! -f "$CLI_SOURCE" ]; then
    echo "built CLI not found: $CLI_SOURCE" >&2
    exit 72
fi

/usr/bin/install -m 755 "$CLI_SOURCE" "$CLI_DEST"
/bin/bash scripts/sanitize-bundled-tools.sh "$APP_PATH/Contents/MacOS" "$WORKFLOW_TOOLS_DIR"

# Fail before codesign/notarization work if release packaging leaked build or
# Homebrew paths back into the app bundle.
scripts/smoke-test-release-tools.sh "$APP_PATH" --portability-only

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements" \
    --generate-entitlement-der \
    "$CLI_DEST"

# Sign every Mach-O file bundled under Resources/Tools individually.
# `codesign --deep` is deprecated and does not recurse into resource bundles,
# so notarization fails unless the bootstrap binary is signed inside-out.
if [ -d "$WORKFLOW_TOOLS_DIR" ]; then
    while IFS= read -r -d '' candidate; do
        if /usr/bin/file -b "$candidate" | grep -q '^Mach-O'; then
            /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                --options runtime \
                --timestamp \
                --generate-entitlement-der \
                "$candidate"
        fi
    done < <(/usr/bin/find "$WORKFLOW_TOOLS_DIR" -type f -print0)
fi

# Outer app signing seals the bundle. Every nested Mach-O was signed above,
# so we deliberately omit `--deep` (which can strip or overwrite those inner
# signatures in unpredictable ways on recent macOS releases).
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
scripts/smoke-test-release-tools.sh "$APP_PATH"

APP_NOTARY_ZIP="${RELEASE_DIR}/Lungfish-app-notary.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"

/usr/bin/xcrun notarytool submit "$APP_NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$APP_NOTARY_LOG"

rm -f "$APP_NOTARY_ZIP"

/usr/bin/xcrun stapler staple "$APP_PATH"

/usr/bin/ditto "$APP_PATH" "$RELEASE_APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
DMG_PATH="${RELEASE_DIR}/Lungfish-${VERSION}-arm64.dmg"
DMG_STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lungfish-dmg.XXXXXX")
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT

/usr/bin/ditto "$APP_PATH" "${DMG_STAGING_DIR}/Lungfish.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

/usr/bin/hdiutil create \
    -volname "Lungfish" \
    -srcfolder "$DMG_STAGING_DIR" \
    -format UDZO \
    "$DMG_PATH"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --timestamp \
    --generate-entitlement-der \
    "$DMG_PATH"

/usr/bin/xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$DMG_NOTARY_LOG"

/usr/bin/xcrun stapler staple "$DMG_PATH"

DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
COMMIT_SHA=$(git rev-parse HEAD)

cat >"$METADATA_PATH" <<EOF
version=${VERSION}
git_commit=${COMMIT_SHA}
signing_identity=${SIGNING_IDENTITY}
team_id=${TEAM_ID}
notary_profile=${NOTARY_PROFILE}
archive_path=${ARCHIVE_PATH}
app_path=${APP_PATH}
release_app_path=${RELEASE_APP_PATH}
DMG_PATH=${DMG_PATH}
dmg_sha256=${DMG_SHA}
app_notary_log=${APP_NOTARY_LOG}
dmg_notary_log=${DMG_NOTARY_LOG}
EOF

printf 'Release complete:\n'
printf '  App: %s\n' "$RELEASE_APP_PATH"
printf '  DMG: %s\n' "$DMG_PATH"
printf '  Metadata: %s\n' "$METADATA_PATH"
