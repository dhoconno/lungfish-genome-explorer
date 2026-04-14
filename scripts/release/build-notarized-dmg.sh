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
Usage: build-notarized-dmg.sh --signing-identity "Developer ID Application: Example (TEAMID)" --team-id TEAMID --notary-profile PROFILE [--scratch-path PATH] [--archive-path PATH] [--release-dir PATH]

Required:
  --signing-identity  Developer ID Application identity used for codesign
  --team-id           Apple Developer Team ID
  --notary-profile    Keychain profile configured for xcrun notarytool

Optional:
  --scratch-path      SwiftPM scratch path for lungfish-cli build (default: .build/xcode-cli-release)
  --archive-path      Archive output path (default: build/Release/Lungfish.xcarchive)
  --release-dir       Release directory (default: build/Release)
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

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 69
    fi
}

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

cd "$PROJECT_ROOT"

xcodebuild -project Lungfish.xcodeproj \
    -scheme Lungfish \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    EXCLUDED_ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=YES \
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
    --scratch-path "$SCRATCH_PATH"

CLI_SOURCE="${SCRATCH_PATH}/arm64-apple-macosx/release/lungfish-cli"
CLI_DEST="${APP_PATH}/Contents/MacOS/lungfish-cli"

if [ ! -f "$CLI_SOURCE" ]; then
    echo "built CLI not found: $CLI_SOURCE" >&2
    exit 72
fi

/usr/bin/install -m 755 "$CLI_SOURCE" "$CLI_DEST"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements" \
    --generate-entitlement-der \
    "$CLI_DEST"

# Sign every Mach-O file bundled under Resources/Tools individually.
# `codesign --deep` is deprecated and does not recurse into resource bundles,
# so notarization fails with "not signed with a valid Developer ID certificate"
# on each bundled bioinformatics tool. We must sign inside-out.
WORKFLOW_TOOLS_DIR="${APP_PATH}/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"

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
