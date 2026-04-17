#!/bin/bash
#
# update-tool-versions.sh - Refresh the micromamba bootstrap manifest.
#
# Micromamba is the only remaining bundled tool. This script reports its pinned
# version, refreshes manifest metadata, and can rebuild the bootstrap binary.
#
# Usage:
#   ./scripts/update-tool-versions.sh --check
#   ./scripts/update-tool-versions.sh --update
#   ./scripts/update-tool-versions.sh --rebuild [--arch arm64|x86_64|universal]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
VERSIONS_FILE="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools/VERSIONS.txt"

MODE="check"
JSON_OUTPUT=false
TARGET_ARCH=""

resolve_build_timestamp_iso8601() {
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

resolve_build_timestamp_display() {
    local timestamp="$1"
    /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +"%Y-%m-%d %H:%M:%S UTC"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            MODE="check"
            shift
            ;;
        --update)
            MODE="update"
            shift
            ;;
        --rebuild)
            MODE="rebuild"
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --help)
            head -20 "$0" | tail -15
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$MANIFEST" ]; then
    echo "Error: tool-versions.json not found at $MANIFEST" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

RESOLVED_BUILD_TIMESTAMP_ISO="$(resolve_build_timestamp_iso8601)"
RESOLVED_BUILD_TIMESTAMP_DISPLAY="$(resolve_build_timestamp_display "$RESOLVED_BUILD_TIMESTAMP_ISO")"

read_micromamba_version() {
    jq -r '.tools[] | select(.name == "micromamba") | .version' "$MANIFEST"
}

resolve_bundle_architecture() {
    local configured_arch

    if [ -n "$TARGET_ARCH" ]; then
        configured_arch="$TARGET_ARCH"
    else
        configured_arch=$(jq -r '.buildArchitecture // empty' "$MANIFEST")
    fi

    case "$configured_arch" in
        arm64|x86_64|universal)
            printf '%s\n' "$configured_arch"
            ;;
        "")
            printf 'arm64\n'
            ;;
        *)
            echo "Error: unsupported architecture '$configured_arch'. Expected arm64, x86_64, or universal." >&2
            exit 1
            ;;
    esac
}

regenerate_versions_txt() {
    local version
    local arch
    version=$(read_micromamba_version)
    arch=$(jq -r '.buildArchitecture' "$MANIFEST")

    cat > "$VERSIONS_FILE" <<EOF
Lungfish Bundled Bootstrap Tools
=================================

This directory contains the bundled bootstrap binary used by Lungfish.
Only micromamba remains bundled here; all other bioinformatics tools are
managed separately.

Versions:
- micromamba: $version (BSD-3-Clause license)

Build date: $RESOLVED_BUILD_TIMESTAMP_DISPLAY
Build architecture: $arch

Source URLs:
- micromamba: https://github.com/mamba-org/mamba

Licenses:
- micromamba: https://github.com/mamba-org/mamba/blob/main/LICENSE
EOF
}

refresh_manifest_metadata() {
    local arch="${1:-$(resolve_bundle_architecture)}"

    local tmp_manifest
    tmp_manifest=$(mktemp)
    jq --arg arch "$arch" --arg ts "$RESOLVED_BUILD_TIMESTAMP_ISO" \
        '.buildArchitecture = $arch | .lastUpdated = $ts' \
        "$MANIFEST" > "$tmp_manifest"
    mv "$tmp_manifest" "$MANIFEST"
}

check_status() {
    local version
    version=$(read_micromamba_version)

    if $JSON_OUTPUT; then
        jq -n \
            --arg ts "$RESOLVED_BUILD_TIMESTAMP_ISO" \
            --arg version "$version" \
            '{"timestamp": $ts, "updatesAvailable": 0, "tools": [{"name": "micromamba", "current": $version, "latest": $version, "status": "pinned"}]}'
        return
    fi

    echo "micromamba is pinned at $version"
    echo "All bundled tools are up to date."
}

case "$MODE" in
    check)
        check_status
        ;;
    update)
        refresh_manifest_metadata
        regenerate_versions_txt
        echo "Refreshed micromamba manifest metadata."
        ;;
    rebuild)
        target_arch=$(resolve_bundle_architecture)
        refresh_manifest_metadata "$target_arch"
        export LUNGFISH_BUILD_TIMESTAMP="$RESOLVED_BUILD_TIMESTAMP_ISO"
        "$SCRIPT_DIR/bundle-native-tools.sh" --arch "$target_arch"
        ;;
esac
