#!/bin/bash
# build-app.sh - Builds Lungfish.app bundle from SPM executable
# Copyright (c) 2024 Lungfish Contributors
# SPDX-License-Identifier: MIT

set -e

# Configuration
APP_NAME="Lungfish"
BUNDLE_ID="com.lungfish.browser"
DEBUG_BUNDLE_ID="com.lungfish.browser.debug"
BUNDLE_NAME="Lungfish"
DEBUG_BUNDLE_NAME="Lungfish Debug"
BUNDLE_DISPLAY_NAME="Lungfish Genome Browser"
DEBUG_BUNDLE_DISPLAY_NAME="Lungfish Genome Browser Debug"
# VERSION is sourced from Lungfish.xcodeproj's MARKETING_VERSION below (after
# PROJECT_ROOT is resolved) so the debug bundle and the notarized build share a
# single version source of truth.
VERSION=""
BUILD_NUMBER="1"
CONFIGURATION="release"
SKIP_BUILD=0
LOG_DIR=""

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Shared source Info.plist (consumed by both this script and Lungfish.xcodeproj)
SHARED_INFO_PLIST="$PROJECT_ROOT/Lungfish-Info.plist"
CLI_ENTITLEMENTS="$PROJECT_ROOT/lungfish-cli.entitlements"

# Single source of truth for the version + minimum OS: the xcodeproj settings,
# so the debug bundle and the notarized build never diverge.
VERSION="$(/usr/bin/grep -m1 'MARKETING_VERSION' "$PROJECT_ROOT/Lungfish.xcodeproj/project.pbxproj" | /usr/bin/sed -E 's/.*= *"?([^";]+)"?;.*/\1/')"
if [ -z "$VERSION" ]; then
    echo "Error: could not read MARKETING_VERSION from Lungfish.xcodeproj" >&2
    exit 1
fi
MINIMUM_SYSTEM_VERSION="$(/usr/bin/grep -m1 'MACOSX_DEPLOYMENT_TARGET' "$PROJECT_ROOT/Lungfish.xcodeproj/project.pbxproj" | /usr/bin/sed -E 's/.*= *"?([^";]+)"?;.*/\1/')"
if [ -z "$MINIMUM_SYSTEM_VERSION" ]; then
    MINIMUM_SYSTEM_VERSION="26.0"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [--configuration release|debug] [--skip-build] [--log-dir PATH]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --configuration" >&2
                usage >&2
                exit 64
            fi
            CONFIGURATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        --debug)
            CONFIGURATION="debug"
            shift
            ;;
        --release)
            CONFIGURATION="release"
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --log-dir)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --log-dir" >&2
                usage >&2
                exit 64
            fi
            LOG_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -n "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    LOG_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    LOG_FILE="$LOG_DIR/build-app-${CONFIGURATION}-${LOG_STAMP}.log"
    exec > >(tee "$LOG_FILE") 2>&1
    echo "Writing build log to $LOG_FILE"
fi

case "$CONFIGURATION" in
    release)
        BUILD_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/release"
        APP_DIR="$PROJECT_ROOT/build/$APP_NAME.app"
        BUILD_LABEL="release"
        ;;
    debug)
        BUILD_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/debug"
        APP_DIR="$PROJECT_ROOT/build/Debug/$APP_NAME.app"
        BUILD_LABEL="debug"
        ;;
    *)
        echo "Unsupported configuration: $CONFIGURATION" >&2
        usage >&2
        exit 64
        ;;
esac

if [ "$CONFIGURATION" = "debug" ]; then
    BUNDLE_ID="$DEBUG_BUNDLE_ID"
    BUNDLE_NAME="$DEBUG_BUNDLE_NAME"
    BUNDLE_DISPLAY_NAME="$DEBUG_BUNDLE_DISPLAY_NAME"
fi

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo -e "${GREEN}Building Lungfish Genome Browser${NC}"
echo "=================================="
echo "Configuration: $BUILD_LABEL"
echo "Bundle identifier: $BUNDLE_ID"

# Clean previous build
if [ -d "$APP_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    rm -rf "$APP_DIR"
fi

# Build executable
cd "$PROJECT_ROOT"
if [ "$SKIP_BUILD" -eq 1 ]; then
    echo -e "${YELLOW}Reusing existing Apple Silicon ${BUILD_LABEL} executable...${NC}"
else
    echo -e "${GREEN}Building Apple Silicon ${BUILD_LABEL} executable...${NC}"
    if [ "$CONFIGURATION" = "release" ]; then
        swift build -c release --arch arm64
    else
        swift build --arch arm64
    fi
fi

if [ ! -f "$BUILD_DIR/Lungfish" ]; then
    echo -e "${RED}Error: executable not found at $BUILD_DIR/Lungfish${NC}"
    echo -e "${RED}Run without --skip-build first to populate the SwiftPM cache.${NC}"
    exit 1
fi

# Create bundle structure
echo -e "${GREEN}Creating app bundle structure...${NC}"
mkdir -p "$(dirname "$APP_DIR")"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Copy executable
cp "$BUILD_DIR/Lungfish" "$MACOS_DIR/"

CLI_SOURCE="$BUILD_DIR/lungfish-cli"
if [ -f "$CLI_SOURCE" ]; then
    echo -e "${GREEN}Copying bundled CLI...${NC}"
    /usr/bin/install -m 755 "$CLI_SOURCE" "$MACOS_DIR/lungfish-cli"
fi

echo -e "${GREEN}Copying SwiftPM resource bundles...${NC}"
while IFS= read -r -d '' bundle; do
    bundle_name="$(basename "$bundle")"
    case "$bundle_name" in
        *Tests.bundle)
            continue
            ;;
    esac
    cp -R "$bundle" "$RESOURCES_DIR/"
done < <(/usr/bin/find "$BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)

SPARKLE_FRAMEWORK_SOURCE="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]; then
    SPARKLE_FRAMEWORK_SOURCE="$(/usr/bin/find "$PROJECT_ROOT/.build" -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit)"
fi
if [ -z "$SPARKLE_FRAMEWORK_SOURCE" ] || [ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]; then
    echo -e "${RED}Error: Sparkle.framework not found in SwiftPM artifacts${NC}"
    exit 1
fi
echo -e "${GREEN}Copying Sparkle framework...${NC}"
/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"

if ! /usr/bin/otool -l "$MACOS_DIR/Lungfish" | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null; then
    echo -e "${GREEN}Adding app framework rpath...${NC}"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Lungfish"
fi

# Create Info.plist from the shared source plist.
#
# Lungfish-Info.plist is the single source of truth for the document-type and
# exported-UTI registrations (shared with Lungfish.xcodeproj via INFOPLIST_FILE).
# It contains $(BUILD_SETTING) placeholders that Xcode expands during the
# notarized build; here we copy the file and substitute the concrete values for
# this (debug or release) bundle, so the document-type arrays are never
# duplicated and cannot drift between the two build paths.
echo -e "${GREEN}Creating Info.plist from shared source ($SHARED_INFO_PLIST)...${NC}"
if [ ! -f "$SHARED_INFO_PLIST" ]; then
    echo -e "${RED}Error: shared Info.plist not found at $SHARED_INFO_PLIST${NC}"
    exit 1
fi
cp "$SHARED_INFO_PLIST" "$CONTENTS_DIR/Info.plist"

# Substitute the fields the xcodeproj would otherwise expand from build settings.
/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$BUNDLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$BUNDLE_DISPLAY_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$CONTENTS_DIR/Info.plist"

# The debug/local bundle does not ship Sparkle auto-update (no signing key here);
# remove the feed/key so SparkleUpdaterBridge stays disabled.
/usr/bin/plutil -remove SUFeedURL "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
/usr/bin/plutil -remove SUPublicEDKey "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
/usr/bin/plutil -remove SUVerifyUpdateBeforeExtraction "$CONTENTS_DIR/Info.plist" 2>/dev/null || true

if ! /usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null; then
    echo -e "${RED}Error: generated Info.plist failed validation${NC}"
    exit 1
fi


# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Copy icon if exists
APP_ICON_SOURCE="$PROJECT_ROOT/Sources/Lungfish/AppIcon.icns"
if [ -f "$APP_ICON_SOURCE" ]; then
    echo -e "${GREEN}Copying app icon...${NC}"
    cp "$APP_ICON_SOURCE" "$RESOURCES_DIR/"
else
    echo -e "${YELLOW}Warning: AppIcon.icns not found at $APP_ICON_SOURCE${NC}"
    echo -e "${YELLOW}The app will use a generic icon until an icon is provided.${NC}"
fi

# Copy THIRD-PARTY-NOTICES into Resources
if [ -f "$PROJECT_ROOT/THIRD-PARTY-NOTICES" ]; then
    echo -e "${GREEN}Copying third-party notices...${NC}"
    cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES" "$RESOURCES_DIR/"
fi

# Copy Help Book resources if available
HELP_BOOK_SRC="$PROJECT_ROOT/Sources/LungfishApp/Resources/HelpBook/Lungfish.help"
HELP_BOOK_DEST="$RESOURCES_DIR/Lungfish.help"
if [ -d "$HELP_BOOK_SRC" ]; then
    echo -e "${GREEN}Copying Help Book resources...${NC}"
    cp -R "$HELP_BOOK_SRC" "$HELP_BOOK_DEST"

    HELP_LOCALE_DIR="$HELP_BOOK_DEST/Contents/Resources/en.lproj"
    HELP_INDEX_PATH="$HELP_LOCALE_DIR/search.helpindex"
    if command -v hiutil >/dev/null 2>&1 && [ -d "$HELP_LOCALE_DIR" ]; then
        echo -e "${GREEN}Building Help Book search index...${NC}"
        hiutil -C -a -s en "$HELP_INDEX_PATH" "$HELP_LOCALE_DIR" >/dev/null 2>&1 || true
    fi
else
    echo -e "${YELLOW}Warning: Help Book bundle not found at $HELP_BOOK_SRC${NC}"
fi

WORKFLOW_BUNDLE_DIR="$RESOURCES_DIR/LungfishGenomeBrowser_LungfishWorkflow.bundle"
WORKFLOW_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Tools"
if [ ! -d "$WORKFLOW_TOOLS_DIR" ]; then
    WORKFLOW_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Contents/Resources/Tools"
fi
if [ -d "$WORKFLOW_TOOLS_DIR" ]; then
    if [ "$CONFIGURATION" = "release" ]; then
        echo -e "${GREEN}Sanitizing bundled executables and workflow tools...${NC}"
        /bin/bash "$PROJECT_ROOT/scripts/sanitize-bundled-tools.sh" "$MACOS_DIR" "$WORKFLOW_TOOLS_DIR"
    else
        echo -e "${GREEN}Sanitizing bundled workflow tools...${NC}"
        /bin/bash "$PROJECT_ROOT/scripts/sanitize-bundled-tools.sh" "$WORKFLOW_TOOLS_DIR"
    fi
fi

if [ -f "$MACOS_DIR/lungfish-cli" ]; then
    echo -e "${GREEN}Ad-hoc signing bundled CLI with CLI entitlements...${NC}"
    codesign --force --sign - --options runtime --entitlements "$CLI_ENTITLEMENTS" "$MACOS_DIR/lungfish-cli"
fi

echo -e "${GREEN}Ad-hoc signing app bundle for local launch...${NC}"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=4 "$APP_DIR"

# Print success message
echo ""
echo -e "${GREEN}App bundle created successfully!${NC}"
echo "Location: $APP_DIR"
echo ""
echo "To run the app:"
echo "  open \"$APP_DIR\""
echo ""
echo "To code sign for distribution (requires Apple Developer ID):"
echo "  codesign --force --sign \"Developer ID Application: Your Name\" --options runtime \"$APP_DIR\""
echo ""
echo "To create a DMG for distribution:"
echo "  hdiutil create -volname \"Lungfish\" -srcfolder \"$APP_DIR\" -ov -format UDZO \"build/Lungfish.dmg\""
