#!/bin/bash
# Relocate and validate a self-contained local Debug app without launching UI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTRACT_SCRIPT="$PROJECT_ROOT/scripts/release/release_contract.py"

usage() {
    echo "Usage: $(basename "$0") APP_PATH [--compiling-build-dir PATH]" >&2
}

if [ "$#" -lt 1 ]; then
    usage
    exit 64
fi

SOURCE_APP="$1"
shift
COMPILING_BUILD_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --compiling-build-dir)
            if [ "$#" -lt 2 ]; then
                usage
                exit 64
            fi
            COMPILING_BUILD_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 64
            ;;
    esac
done

if [ ! -d "$SOURCE_APP" ]; then
    echo "Debug app does not exist: $SOURCE_APP" >&2
    exit 1
fi

PROFILE_OUTPUT="$(python3 "$CONTRACT_SCRIPT" shell-profile --profile debug)"
APP_BUNDLE_FILENAME=""
APP_DISPLAY_NAME=""
APP_SHORT_NAME=""
APP_BUNDLE_IDENTIFIER=""
RELEASE_CHANNEL=""
while IFS='=' read -r key value; do
    case "$key" in
        APP_BUNDLE_FILENAME) APP_BUNDLE_FILENAME="$value" ;;
        APP_DISPLAY_NAME) APP_DISPLAY_NAME="$value" ;;
        APP_SHORT_NAME) APP_SHORT_NAME="$value" ;;
        APP_BUNDLE_IDENTIFIER) APP_BUNDLE_IDENTIFIER="$value" ;;
        RELEASE_CHANNEL) RELEASE_CHANNEL="$value" ;;
        IS_RELEASE|PUBLISHABLE|UPDATER_ENABLED)
            if [ "$value" != "false" ]; then
                echo "Debug contract permits release, publication, or updates" >&2
                exit 1
            fi
            ;;
        *)
            echo "Unexpected Debug contract key: $key" >&2
            exit 1
            ;;
    esac
done <<< "$PROFILE_OUTPUT"

if [ "$(basename "$SOURCE_APP")" != "$APP_BUNDLE_FILENAME" ]; then
    echo "Debug wrapper must be exactly $APP_BUNDLE_FILENAME" >&2
    exit 1
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lungfish-debug-smoke.XXXXXX")"
HIDDEN_BUILD_DIR=""
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$HIDDEN_BUILD_DIR" ] && [ -d "$HIDDEN_BUILD_DIR" ]; then
        mv "$HIDDEN_BUILD_DIR" "$COMPILING_BUILD_DIR"
    fi
    /bin/rm -rf "$SMOKE_ROOT"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

RELOCATED_APP="$SMOKE_ROOT/relocated/$APP_BUNDLE_FILENAME"
mkdir -p "$(dirname "$RELOCATED_APP")"
/usr/bin/ditto "$SOURCE_APP" "$RELOCATED_APP"

INFO_PLIST="$RELOCATED_APP/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "Relocated Debug app has no Info.plist" >&2
    exit 1
fi

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null
}

if [ "$(plist_value CFBundleDisplayName)" != "$APP_DISPLAY_NAME" ] \
    || [ "$(plist_value CFBundleName)" != "$APP_SHORT_NAME" ] \
    || [ "$(plist_value CFBundleIdentifier)" != "$APP_BUNDLE_IDENTIFIER" ] \
    || [ "$(plist_value LungfishReleaseChannel)" != "$RELEASE_CHANNEL" ]; then
    echo "Relocated Debug plist identity does not match the strict contract" >&2
    exit 1
fi

for sparkle_key in SUFeedURL SUPublicEDKey SUVerifyUpdateBeforeExtraction; do
    if /usr/libexec/PlistBuddy -c "Print :$sparkle_key" "$INFO_PLIST" >/dev/null 2>&1; then
        echo "Debug plist must not contain Sparkle key $sparkle_key" >&2
        exit 1
    fi
done

RESOURCES_DIR="$RELOCATED_APP/Contents/Resources"
resource_bundle_count=0
for resource_bundle in "$RESOURCES_DIR"/*.bundle; do
    if [ ! -d "$resource_bundle" ]; then
        continue
    fi
    bundle_name="$(basename "$resource_bundle")"
    case "$bundle_name" in
        *Tests.bundle) continue ;;
    esac
    resource_bundle_count=$((resource_bundle_count + 1))
done
if [ "$resource_bundle_count" -eq 0 ]; then
    echo "Relocated Debug app contains no runtime resource bundles" >&2
    exit 1
fi

if [ -n "$COMPILING_BUILD_DIR" ]; then
    if [ "$(basename "$COMPILING_BUILD_DIR")" != ".build" ] \
        || [ ! -f "$(dirname "$COMPILING_BUILD_DIR")/Package.swift" ] \
        || [ ! -d "$COMPILING_BUILD_DIR" ]; then
        echo "--compiling-build-dir must name an existing package .build directory" >&2
        exit 1
    fi
    HIDDEN_BUILD_DIR="${COMPILING_BUILD_DIR}.debug-resource-smoke-hidden"
    if [ -e "$HIDDEN_BUILD_DIR" ]; then
        echo "Temporary hidden build path already exists: $HIDDEN_BUILD_DIR" >&2
        exit 1
    fi
    mv "$COMPILING_BUILD_DIR" "$HIDDEN_BUILD_DIR"
fi

ISOLATED_HOME="$SMOKE_ROOT/home"
ISOLATED_STORAGE="$SMOKE_ROOT/storage"
ISOLATED_TMP="$SMOKE_ROOT/tmp"
mkdir -p "$ISOLATED_HOME" "$ISOLATED_STORAGE" "$ISOLATED_TMP"
CLI="$RELOCATED_APP/Contents/MacOS/lungfish-cli"
if [ ! -x "$CLI" ]; then
    echo "Relocated Debug app has no executable embedded CLI" >&2
    exit 1
fi

probe_output="$({
    cd "$SMOKE_ROOT"
    HOME="$ISOLATED_HOME" \
        CFFIXED_USER_HOME="$ISOLATED_HOME" \
        TMPDIR="$ISOLATED_TMP" \
        LUNGFISH_STORAGE_ROOT="$ISOLATED_STORAGE" \
        "$CLI" debug resource-smoke
} 2>&1)"
if ! printf '%s\n' "$probe_output" | /usr/bin/grep -Fx "debug-resource-smoke-ok" >/dev/null; then
    echo "Relocated Debug resource probe failed: $probe_output" >&2
    exit 1
fi

echo "Debug relocation/resource smoke passed: $RELOCATED_APP"
