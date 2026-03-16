#!/bin/bash
#
# build-cutadapt.sh - Build standalone cutadapt binary using PyInstaller
#
# Creates an arm64 macOS binary of cutadapt 4.9 for bundling with Lungfish.
# cutadapt is MIT-licensed; all its dependencies (dnaio, xopen, isal) are
# MIT/PSF/BSD — no GPL contamination.
#
# Usage:
#   ./scripts/build-cutadapt.sh [--output-dir <dir>]
#
# Options:
#   --output-dir <dir>  Output directory (default: Sources/LungfishWorkflow/Resources/Tools)
#   --clean             Remove virtualenv and rebuild from scratch
#   --help              Show this help message
#
# Requirements:
#   - Python 3.10+ (python3)
#   - pip

set -e

CUTADAPT_VERSION="4.9"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/cutadapt-build"
DEFAULT_OUTPUT_DIR="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools"

OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
CLEAN_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
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
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== Building cutadapt $CUTADAPT_VERSION standalone binary ==="

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Using Python $PYTHON_VERSION"

if $CLEAN_BUILD && [ -d "$BUILD_DIR" ]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

# Create virtualenv
VENV_DIR="$BUILD_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtualenv..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Install cutadapt and PyInstaller
echo "Installing cutadapt==$CUTADAPT_VERSION and PyInstaller..."
pip install --quiet --upgrade pip
pip install --quiet "cutadapt==$CUTADAPT_VERSION" pyinstaller

# Verify cutadapt works
echo "Verifying cutadapt installation..."
cutadapt --version

# Create PyInstaller spec
SPEC_FILE="$BUILD_DIR/cutadapt.spec"
cat > "$SPEC_FILE" << 'PYSPEC'
# -*- mode: python ; coding: utf-8 -*-
import importlib
import os
from PyInstaller.utils.hooks import collect_submodules, collect_data_files

# Collect cutadapt and its native extensions
block_cipher = None

# Find cutadapt package location
cutadapt_pkg = importlib.import_module('cutadapt')
cutadapt_dir = os.path.dirname(cutadapt_pkg.__file__)

# Find dnaio package (cutadapt's FASTQ parser, has C extensions)
dnaio_pkg = importlib.import_module('dnaio')
dnaio_dir = os.path.dirname(dnaio_pkg.__file__)

a = Analysis(
    [os.path.join(cutadapt_dir, '__main__.py')],
    pathex=[],
    binaries=[],
    datas=collect_data_files('cutadapt'),
    hiddenimports=(
        collect_submodules('cutadapt')
        + collect_submodules('dnaio')
        + ['xopen', 'isal']
    ),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'numpy', 'scipy', 'pandas'],
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='cutadapt',
    debug=False,
    bootloader_ignore_signals=False,
    strip=True,
    upx=False,
    console=True,
    target_arch='arm64',
)
PYSPEC

# Build with PyInstaller
echo "Building standalone binary with PyInstaller..."
cd "$BUILD_DIR"
pyinstaller --clean --noconfirm "$SPEC_FILE"

# Verify the binary works
BINARY="$BUILD_DIR/dist/cutadapt"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found at $BINARY"
    deactivate
    exit 1
fi

echo "Verifying standalone binary..."
STANDALONE_VERSION=$("$BINARY" --version 2>&1)
echo "Standalone cutadapt version: $STANDALONE_VERSION"

# Check architecture
ARCH=$(file "$BINARY" | grep -o 'arm64\|x86_64')
echo "Architecture: $ARCH"

# Copy to output directory
mkdir -p "$OUTPUT_DIR"
cp "$BINARY" "$OUTPUT_DIR/cutadapt"
chmod +x "$OUTPUT_DIR/cutadapt"

deactivate

BINARY_SIZE=$(du -h "$OUTPUT_DIR/cutadapt" | cut -f1)
echo ""
echo "=== Build complete ==="
echo "Binary: $OUTPUT_DIR/cutadapt"
echo "Size: $BINARY_SIZE"
echo "Version: $STANDALONE_VERSION"
echo "Architecture: $ARCH"
echo ""
echo "License chain (all MIT-compatible):"
echo "  cutadapt $CUTADAPT_VERSION — MIT"
echo "  dnaio — MIT"
echo "  xopen — MIT"
echo "  isal (Intel ISA-L) — BSD-3-Clause"
echo "  PyInstaller — GPL-2.0 w/ special exception (output is NOT GPL)"
