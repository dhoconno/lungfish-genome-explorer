#!/bin/bash
# test-container-runtime.sh - Verify Apple Containerization runtime
# Runs system checks and then the XCTest integration test.
#
# Usage:
#   ./scripts/test-container-runtime.sh           # Full test (pulls image, runs container)
#   ./scripts/test-container-runtime.sh --quick    # Init-only test (no network required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "      $1"; }

echo "============================================"
echo " Apple Containerization Runtime Verification"
echo "============================================"
echo ""

# --- 1. System Requirements ---
echo "--- System Requirements ---"

# macOS version
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -ge 26 ]; then
    pass "macOS $(sw_vers -productVersion) (requires 26+)"
else
    fail "macOS $(sw_vers -productVersion) - requires macOS 26+"
    exit 1
fi

# Architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    pass "Architecture: $ARCH (Apple Silicon)"
else
    fail "Architecture: $ARCH - requires arm64 (Apple Silicon)"
    exit 1
fi

# Swift version
SWIFT_VER=$(swift --version 2>&1 | head -1)
pass "Swift: $SWIFT_VER"

echo ""

# --- 2. Bundled Resources ---
echo "--- Bundled Resources ---"

KERNEL_PATH="$PROJECT_DIR/Sources/LungfishWorkflow/Resources/Containerization/vmlinux"
INITFS_PATH="$PROJECT_DIR/Sources/LungfishWorkflow/Resources/Containerization/init.rootfs.tar.gz"

if [ -f "$KERNEL_PATH" ]; then
    KERNEL_SIZE=$(ls -lh "$KERNEL_PATH" | awk '{print $5}')
    pass "vmlinux kernel found ($KERNEL_SIZE)"
else
    fail "vmlinux kernel not found at $KERNEL_PATH"
    info "Download from https://github.com/apple/containerization or build from source"
    exit 1
fi

if [ -f "$INITFS_PATH" ]; then
    INITFS_SIZE=$(ls -lh "$INITFS_PATH" | awk '{print $5}')
    pass "init.rootfs.tar.gz found ($INITFS_SIZE)"
else
    fail "init.rootfs.tar.gz not found at $INITFS_PATH"
    info "Build vminit from the containerization repository"
    exit 1
fi

echo ""

# --- 3. Container CLI (optional) ---
echo "--- Container CLI (optional) ---"

if command -v container &>/dev/null; then
    CONTAINER_VER=$(container --version 2>&1 || echo "unknown")
    pass "container CLI installed: $CONTAINER_VER"

    # Check if container system is running
    if container system info &>/dev/null 2>&1; then
        pass "container system is running"
    else
        warn "container system is not running"
        info "Start with: container system start"
        info "Or via brew: brew services start container"
    fi
else
    warn "container CLI not installed (optional - not required for programmatic API)"
    info "Install with: brew install container"
    info "The Containerization Swift framework is used directly via SPM."
fi

echo ""

# --- 4. SPM Dependency Check ---
echo "--- SPM Dependencies ---"

cd "$PROJECT_DIR"

if [ -d ".build/checkouts/containerization" ]; then
    CZ_TAG=$(cd .build/checkouts/containerization && git describe --tags 2>/dev/null || echo "unknown")
    pass "Containerization package checked out ($CZ_TAG)"
else
    warn "Containerization package not yet resolved"
    info "Running swift package resolve..."
    swift package resolve 2>&1 | tail -3
fi

echo ""

# --- 5. Build Test Target ---
echo "--- Building Test Target ---"

info "Building LungfishWorkflowTests..."
if swift build --build-tests 2>&1 | tail -5; then
    pass "Test target built successfully"
else
    fail "Failed to build test target"
    exit 1
fi

echo ""

# --- 6. Run Integration Tests ---
echo "--- Running Integration Tests ---"

QUICK_FLAG="${1:-}"

if [ "$QUICK_FLAG" = "--quick" ]; then
    info "Running init-only tests (--quick mode, no network required)..."
    FILTER="AppleContainerRuntimeIntegrationTests/testRuntimeInitialization"
else
    info "Running full integration tests (requires network for image pull)..."
    FILTER="AppleContainerRuntimeIntegrationTests"
fi

echo ""

if swift test --filter "$FILTER" 2>&1; then
    echo ""
    pass "Integration tests passed!"
else
    echo ""
    fail "Integration tests failed. See output above for details."
    exit 1
fi

echo ""
echo "============================================"
echo " Verification Complete"
echo "============================================"
