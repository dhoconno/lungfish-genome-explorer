#!/bin/bash
#
# bundle-native-tools.sh - Download and stage the bundled bootstrap binary.
#
# Only micromamba remains bundled. All other bioinformatics tools are managed
# through the conda-based provisioning flow.
#
# Usage:
#   ./scripts/bundle-native-tools.sh [--output-dir <dir>] [--arch <arch>]
#
# Options:
#   --output-dir <dir>  Output directory for the bundled bootstrap binary
#                       (default: Sources/LungfishWorkflow/Resources/Tools)
#   --arch <arch>       Build for specific architecture: arm64, x86_64, or
#                       universal (default: arm64)
#   --clean             Clean build directories before building
#   --help              Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
BUILD_DIR="$PROJECT_ROOT/.build/tools"
DEFAULT_OUTPUT_DIR="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "Error: tool-versions.json not found at $MANIFEST" >&2
    exit 1
fi

MICROMAMBA_VERSION=$(jq -r '.tools[] | select(.name == "micromamba") | .version' "$MANIFEST")
if [ -z "$MICROMAMBA_VERSION" ] || [ "$MICROMAMBA_VERSION" = "null" ]; then
    echo "Error: micromamba version not found in $MANIFEST" >&2
    exit 1
fi

OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
TARGET_ARCH="arm64"
CLEAN_BUILD=false

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

remove_retired_bundle_entries() {
    local root="$1"

    local retired_entries=(
        "bbtools"
        "jre"
        "fastp"
        "seqkit"
        "samtools"
        "bcftools"
        "bgzip"
        "tabix"
        "bedToBigBed"
        "bedGraphToBigWig"
        "htslib"
        "pigz"
        "vsearch"
        "cutadapt"
        "sra-human-scrubber"
        "sra-tools"
        "scrubber"
    )

    local retired_entry
    for retired_entry in "${retired_entries[@]}"; do
        rm -rf "$root/$retired_entry"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
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

RESOLVED_BUILD_TIMESTAMP_ISO="$(resolve_build_timestamp_iso8601)"
RESOLVED_BUILD_TIMESTAMP_DISPLAY="$(resolve_build_timestamp_display "$RESOLVED_BUILD_TIMESTAMP_ISO")"

download_micromamba() {
    local arch="$1"
    local output_path="$2"

    local url
    case "$arch" in
        arm64)
            url="https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION/micromamba-osx-arm64"
            ;;
        x86_64)
            url="https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION/micromamba-osx-64"
            ;;
        *)
            echo "Unsupported micromamba architecture: $arch" >&2
            exit 1
            ;;
    esac

    mkdir -p "$(dirname "$output_path")"
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 1 --retry-all-errors \
        -o "$output_path" "$url"
    chmod +x "$output_path"
}

create_universal_micromamba() {
    local arm64_path="$BUILD_DIR/arm64/micromamba"
    local x86_64_path="$BUILD_DIR/x86_64/micromamba"
    local output_path="$OUTPUT_DIR/micromamba"

    lipo -create -output "$output_path" "$arm64_path" "$x86_64_path"
    chmod +x "$output_path"
}

refresh_manifest_file() {
    local tmp_manifest
    tmp_manifest=$(mktemp)
    jq --arg arch "$TARGET_ARCH" --arg ts "$RESOLVED_BUILD_TIMESTAMP_ISO" \
        '.buildArchitecture = $arch | .lastUpdated = $ts' \
        "$MANIFEST" > "$tmp_manifest"
    mv "$tmp_manifest" "$MANIFEST"
}

sync_manifest_to_output() {
    local output_manifest="$OUTPUT_DIR/tool-versions.json"

    if [ "$output_manifest" != "$MANIFEST" ]; then
        cp "$MANIFEST" "$output_manifest"
    fi
}

write_versions_file() {
    cat > "$OUTPUT_DIR/VERSIONS.txt" <<EOF
Lungfish Bundled Bootstrap Tools
=================================

This directory contains the bundled bootstrap binary used by Lungfish.
Only micromamba remains bundled here; all other bioinformatics tools are
managed separately.

Versions:
- micromamba: $MICROMAMBA_VERSION (BSD-3-Clause license)

Build date: $RESOLVED_BUILD_TIMESTAMP_DISPLAY
Build architecture: $TARGET_ARCH

Source URLs:
- micromamba: https://github.com/mamba-org/mamba

Licenses:
- micromamba: https://github.com/mamba-org/mamba/blob/main/LICENSE
EOF
}

if [ "$CLEAN_BUILD" = true ] && [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

remove_retired_bundle_entries "$OUTPUT_DIR"

case "$TARGET_ARCH" in
    universal)
        download_micromamba arm64 "$BUILD_DIR/arm64/micromamba"
        download_micromamba x86_64 "$BUILD_DIR/x86_64/micromamba"
        create_universal_micromamba
        ;;
    arm64|x86_64)
        download_micromamba "$TARGET_ARCH" "$OUTPUT_DIR/micromamba"
        ;;
    *)
        echo "Unsupported target architecture for micromamba: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

refresh_manifest_file
sync_manifest_to_output
write_versions_file
