#!/bin/bash
#
# bundle-native-tools.sh - Download and build bioinformatics tools for bundling
#
# This script downloads, compiles, and bundles Apple Silicon bioinformatics tools
# needed by Lungfish.
#
# Tools included:
# - samtools (MIT license) - FASTA/BAM manipulation
# - bcftools (MIT license) - VCF/BCF manipulation
# - htslib (MIT license) - bgzip, tabix
# - UCSC tools (MIT license) - bedToBigBed, bedGraphToBigWig
# - micromamba (BSD-3-Clause) - conda package manager for bundled environments
#
# Usage:
#   ./Scripts/bundle-native-tools.sh [--output-dir <dir>] [--arch <arch>]
#
# Options:
#   --output-dir <dir>  Output directory for tools (default: Sources/LungfishWorkflow/Resources/Tools)
#   --arch <arch>       Build for specific architecture: arm64, x86_64, or universal (default: arm64)
#   --clean             Clean build directories before building
#   --help              Show this help message
#
# Requirements:
#   - Xcode Command Line Tools
#   - curl, tar, make
#   - Rosetta 2 is only needed when explicitly requesting x86_64 or universal outputs

set -e

# Configuration - read from tool-versions.json (single source of truth)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "Error: tool-versions.json not found at $MANIFEST" >&2
    exit 1
fi

# Read versions from the JSON manifest
get_tool_version() { jq -r ".tools[] | select(.name == \"$1\") | .version" "$MANIFEST"; }

SAMTOOLS_VERSION=$(get_tool_version "samtools")
BCFTOOLS_VERSION=$(get_tool_version "bcftools")
HTSLIB_VERSION=$(get_tool_version "htslib")
UCSC_TOOLS_VERSION=$(get_tool_version "ucsc-tools")
MICROMAMBA_VERSION=$(get_tool_version "micromamba")
BUILD_DIR="$PROJECT_ROOT/.build/tools"
DEFAULT_OUTPUT_DIR="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools"

# Parse arguments
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
TARGET_ARCH="arm64"
CLEAN_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
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
            head -30 "$0" | tail -25
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check requirements
check_requirements() {
    log_info "Checking requirements..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed."
        exit 1
    fi

    if ! command -v make &> /dev/null; then
        log_error "make is required. Install Xcode Command Line Tools: xcode-select --install"
        exit 1
    fi

    if ! command -v cc &> /dev/null; then
        log_error "C compiler not found. Install Xcode Command Line Tools: xcode-select --install"
        exit 1
    fi

    log_success "All requirements met."
}

# Create directories
setup_directories() {
    log_info "Setting up directories..."

    if [ "$CLEAN_BUILD" = true ] && [ -d "$BUILD_DIR" ]; then
        log_info "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi

    mkdir -p "$BUILD_DIR"/{src,arm64,x86_64,universal}
    mkdir -p "$OUTPUT_DIR"

    log_success "Directories created."
}

# Download source
download_source() {
    local name=$1
    local url=$2
    local filename=$3

    if [ -f "$BUILD_DIR/src/$filename" ]; then
        log_info "$name already downloaded, skipping..."
        return
    fi

    log_info "Downloading $name..."
    curl -L -o "$BUILD_DIR/src/$filename" "$url"
    log_success "$name downloaded."
}

# Build htslib (provides bgzip, tabix, and is a dependency for samtools/bcftools)
build_htslib() {
    local arch=$1
    local build_dir="$BUILD_DIR/$arch/htslib-$HTSLIB_VERSION"

    log_info "Building htslib for $arch..."

    # Extract source
    if [ ! -d "$build_dir" ]; then
        tar -xjf "$BUILD_DIR/src/htslib-$HTSLIB_VERSION.tar.bz2" -C "$BUILD_DIR/$arch"
    fi

    cd "$build_dir"

    # Configure for architecture (--disable-shared ensures samtools/bcftools link statically)
    if [ "$arch" = "arm64" ]; then
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch arm64" \
            CFLAGS="-O2 -arch arm64" \
            --disable-libcurl \
            --disable-gcs \
            --disable-s3 \
            --disable-shared
    else
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch x86_64" \
            CFLAGS="-O2 -arch x86_64" \
            --disable-libcurl \
            --disable-gcs \
            --disable-s3 \
            --disable-shared
    fi

    make -j$(sysctl -n hw.ncpu)
    make install

    log_success "htslib built for $arch."
}

# Build samtools
build_samtools() {
    local arch=$1
    local build_dir="$BUILD_DIR/$arch/samtools-$SAMTOOLS_VERSION"

    log_info "Building samtools for $arch..."

    # Extract source
    if [ ! -d "$build_dir" ]; then
        tar -xjf "$BUILD_DIR/src/samtools-$SAMTOOLS_VERSION.tar.bz2" -C "$BUILD_DIR/$arch"
    fi

    cd "$build_dir"

    # Configure with htslib source dir (builds htslib internally, links statically)
    if [ "$arch" = "arm64" ]; then
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch arm64" \
            CFLAGS="-O2 -arch arm64" \
            --with-htslib="$BUILD_DIR/$arch/htslib-$HTSLIB_VERSION" \
            --without-curses
    else
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch x86_64" \
            CFLAGS="-O2 -arch x86_64" \
            --with-htslib="$BUILD_DIR/$arch/htslib-$HTSLIB_VERSION" \
            --without-curses
    fi

    make -j$(sysctl -n hw.ncpu)
    make install

    log_success "samtools built for $arch."
}

# Build bcftools
build_bcftools() {
    local arch=$1
    local build_dir="$BUILD_DIR/$arch/bcftools-$BCFTOOLS_VERSION"

    log_info "Building bcftools for $arch..."

    # Extract source
    if [ ! -d "$build_dir" ]; then
        tar -xjf "$BUILD_DIR/src/bcftools-$BCFTOOLS_VERSION.tar.bz2" -C "$BUILD_DIR/$arch"
    fi

    cd "$build_dir"

    # Configure with htslib source dir (builds htslib internally, links statically)
    if [ "$arch" = "arm64" ]; then
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch arm64" \
            CFLAGS="-O2 -arch arm64" \
            --with-htslib="$BUILD_DIR/$arch/htslib-$HTSLIB_VERSION" \
            --disable-perl-filters
    else
        ./configure --prefix="$BUILD_DIR/$arch/install" \
            CC="clang -arch x86_64" \
            CFLAGS="-O2 -arch x86_64" \
            --with-htslib="$BUILD_DIR/$arch/htslib-$HTSLIB_VERSION" \
            --disable-perl-filters
    fi

    make -j$(sysctl -n hw.ncpu)
    make install

    log_success "bcftools built for $arch."
}

# Download UCSC tools (pre-built binaries)
download_ucsc_tools() {
    local arch=$1

    log_info "Downloading UCSC tools for $arch..."

    local ucsc_dir="$BUILD_DIR/$arch/ucsc"
    mkdir -p "$ucsc_dir"

    # UCSC provides pre-built macOS binaries
    # Note: They only provide x86_64, but they work on arm64 via Rosetta
    local base_url="https://hgdownload.soe.ucsc.edu/admin/exe/macOSX.x86_64"

    for tool in bedToBigBed bedGraphToBigWig; do
        if [ ! -f "$ucsc_dir/$tool" ]; then
            log_info "Downloading $tool..."
            curl -L -o "$ucsc_dir/$tool" "$base_url/$tool"
            chmod +x "$ucsc_dir/$tool"
        fi
    done

    log_success "UCSC tools downloaded for $arch."
}

# Download micromamba for a specific architecture.
download_micromamba_arch() {
    local arch=$1
    local build_arch=$2

    local micromamba_dir="$BUILD_DIR/$arch"
    local micromamba_path="$micromamba_dir/micromamba"
    local micromamba_url

    mkdir -p "$micromamba_dir"

    case "$build_arch" in
        arm64)
            micromamba_url="https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION/micromamba-osx-arm64"
            ;;
        x86_64)
            micromamba_url="https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION/micromamba-osx-64"
            ;;
        *)
            log_error "Unsupported micromamba architecture: $build_arch"
            exit 1
            ;;
    esac

    log_info "Downloading micromamba for $build_arch..."
    curl -L -o "$micromamba_path" "$micromamba_url"
    chmod +x "$micromamba_path"

    log_success "micromamba downloaded for $build_arch."
}

# Create universal binary using lipo
create_universal() {
    local name=$1
    local arm64_path=$2
    local x86_64_path=$3
    local output_path=$4

    log_info "Creating universal binary for $name..."

    if [ -f "$arm64_path" ] && [ -f "$x86_64_path" ]; then
        lipo -create -output "$output_path" "$arm64_path" "$x86_64_path"
        log_success "Created universal binary: $name"
    elif [ -f "$arm64_path" ]; then
        cp "$arm64_path" "$output_path"
        log_warning "Only arm64 available for $name"
    elif [ -f "$x86_64_path" ]; then
        cp "$x86_64_path" "$output_path"
        log_warning "Only x86_64 available for $name"
    else
        log_error "No binary found for $name"
        return 1
    fi

    chmod +x "$output_path"
}

# Copy tools to output directory
copy_tools() {
    local arch=$1

    log_info "Copying tools to output directory..."

    if [ "$arch" = "universal" ]; then
        # Create universal binaries
        create_universal "samtools" \
            "$BUILD_DIR/arm64/install/bin/samtools" \
            "$BUILD_DIR/x86_64/install/bin/samtools" \
            "$OUTPUT_DIR/samtools"

        create_universal "bcftools" \
            "$BUILD_DIR/arm64/install/bin/bcftools" \
            "$BUILD_DIR/x86_64/install/bin/bcftools" \
            "$OUTPUT_DIR/bcftools"

        create_universal "bgzip" \
            "$BUILD_DIR/arm64/install/bin/bgzip" \
            "$BUILD_DIR/x86_64/install/bin/bgzip" \
            "$OUTPUT_DIR/bgzip"

        create_universal "tabix" \
            "$BUILD_DIR/arm64/install/bin/tabix" \
            "$BUILD_DIR/x86_64/install/bin/tabix" \
            "$OUTPUT_DIR/tabix"

        create_universal "micromamba" \
            "$BUILD_DIR/arm64/micromamba" \
            "$BUILD_DIR/x86_64/micromamba" \
            "$OUTPUT_DIR/micromamba"

        # UCSC tools are x86_64 only, will run via Rosetta
        cp "$BUILD_DIR/x86_64/ucsc/bedToBigBed" "$OUTPUT_DIR/bedToBigBed"
        cp "$BUILD_DIR/x86_64/ucsc/bedGraphToBigWig" "$OUTPUT_DIR/bedGraphToBigWig"
        chmod +x "$OUTPUT_DIR/bedToBigBed" "$OUTPUT_DIR/bedGraphToBigWig"
    else
        # Single architecture - copy compiled tools
        cp "$BUILD_DIR/$arch/install/bin/samtools" "$OUTPUT_DIR/"
        cp "$BUILD_DIR/$arch/install/bin/bcftools" "$OUTPUT_DIR/"
        cp "$BUILD_DIR/$arch/install/bin/bgzip" "$OUTPUT_DIR/"
        cp "$BUILD_DIR/$arch/install/bin/tabix" "$OUTPUT_DIR/"
        cp "$BUILD_DIR/$arch/micromamba" "$OUTPUT_DIR/"

        # UCSC tools are always x86_64 (downloaded from UCSC)
        # They work on arm64 via Rosetta 2
        cp "$BUILD_DIR/x86_64/ucsc/bedToBigBed" "$OUTPUT_DIR/"
        cp "$BUILD_DIR/x86_64/ucsc/bedGraphToBigWig" "$OUTPUT_DIR/"
        chmod +x "$OUTPUT_DIR"/*
    fi

    log_success "Tools copied to $OUTPUT_DIR"
}

# Create version info file (generated from tool-versions.json)
create_version_info() {
    log_info "Creating version info..."

    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    cat > "$OUTPUT_DIR/VERSIONS.txt" << HEADER
Lungfish Bundled Bioinformatics Tools
======================================

This directory contains pre-built bioinformatics tools bundled with Lungfish.
Bundled tools are distributed under their own licenses; see THIRD-PARTY-NOTICES
and the license URLs below for the exact redistribution terms.

Versions:
HEADER

    jq -r '.tools[] | "- \(.displayName): \(.version) (\(.license) license)"' "$MANIFEST" >> "$OUTPUT_DIR/VERSIONS.txt"

    cat >> "$OUTPUT_DIR/VERSIONS.txt" << MIDDLE

Build date: $timestamp
Build architecture: $TARGET_ARCH

Source URLs:
MIDDLE

    jq -r '.tools[] | "- \(.name): \(.sourceUrl)"' "$MANIFEST" >> "$OUTPUT_DIR/VERSIONS.txt"

    cat >> "$OUTPUT_DIR/VERSIONS.txt" << FOOTER

Licenses:
FOOTER

    jq -r '.tools[] | "- \(.name): \(.licenseUrl)"' "$MANIFEST" >> "$OUTPUT_DIR/VERSIONS.txt"

    # Update buildArchitecture in manifest
    local tmp_manifest
    tmp_manifest=$(mktemp)
    jq --arg arch "$TARGET_ARCH" --arg ts "$timestamp" \
        '.buildArchitecture = $arch | .lastUpdated = $ts' \
        "$MANIFEST" > "$tmp_manifest"
    mv "$tmp_manifest" "$MANIFEST"

    log_success "Version info created."
}

# Main build process
main() {
    echo "=========================================="
    echo "Lungfish Native Tools Builder"
    echo "=========================================="
    echo ""
    echo "Target architecture: $TARGET_ARCH"
    echo "Output directory: $OUTPUT_DIR"
    echo ""

    check_requirements
    setup_directories

    # Download all sources
    log_info "Downloading sources..."
    download_source "htslib" \
        "https://github.com/samtools/htslib/releases/download/$HTSLIB_VERSION/htslib-$HTSLIB_VERSION.tar.bz2" \
        "htslib-$HTSLIB_VERSION.tar.bz2"

    download_source "samtools" \
        "https://github.com/samtools/samtools/releases/download/$SAMTOOLS_VERSION/samtools-$SAMTOOLS_VERSION.tar.bz2" \
        "samtools-$SAMTOOLS_VERSION.tar.bz2"

    download_source "bcftools" \
        "https://github.com/samtools/bcftools/releases/download/$BCFTOOLS_VERSION/bcftools-$BCFTOOLS_VERSION.tar.bz2" \
        "bcftools-$BCFTOOLS_VERSION.tar.bz2"

    # Build for each architecture
    if [ "$TARGET_ARCH" = "universal" ] || [ "$TARGET_ARCH" = "arm64" ]; then
        log_info "Building for arm64..."
        build_htslib arm64
        build_samtools arm64
        build_bcftools arm64
    fi

    if [ "$TARGET_ARCH" = "universal" ] || [ "$TARGET_ARCH" = "x86_64" ]; then
        log_info "Building for x86_64..."
        build_htslib x86_64
        build_samtools x86_64
        build_bcftools x86_64
    fi

    # Download UCSC tools (x86_64 only, works via Rosetta)
    download_ucsc_tools x86_64

    # Download pinned micromamba for the requested architectures.
    if [ "$TARGET_ARCH" = "universal" ]; then
        download_micromamba_arch arm64 arm64
        download_micromamba_arch x86_64 x86_64
    elif [ "$TARGET_ARCH" = "arm64" ] || [ "$TARGET_ARCH" = "x86_64" ]; then
        download_micromamba_arch "$TARGET_ARCH" "$TARGET_ARCH"
    else
        log_error "Unsupported target architecture for micromamba: $TARGET_ARCH"
        exit 1
    fi

    # Copy tools to output
    copy_tools "$TARGET_ARCH"

    # Create version info
    create_version_info

    echo ""
    echo "=========================================="
    log_success "Build complete!"
    echo "=========================================="
    echo ""
    echo "Tools installed to: $OUTPUT_DIR"
    echo ""
    echo "Contents:"
    ls -la "$OUTPUT_DIR"
}

main
