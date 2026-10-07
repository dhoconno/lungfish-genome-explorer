#!/bin/bash
# exfat-tests.sh - Run the tests that need a real ExFAT volume.
#
# Most external SSDs ship formatted ExFAT, and LGE must work on them
# (docs/contracts/EXTERNAL-VOLUMES.md). Tests that need real ExFAT behaviour read
# LUNGFISH_EXFAT_TEST_ROOT, skip when it is unset, and have "ExFAT" in their name.
# This script makes a scratch ExFAT disk image, mounts it, runs those tests against
# it and detaches and deletes the image afterwards.
#
# Usage:
#   scripts/testing/exfat-tests.sh                 # every test whose name contains ExFAT
#   scripts/testing/exfat-tests.sh "Analyses"      # a different name filter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILTER="${1:-ExFAT}"

# mount(8) reports the resolved path (/private/var, not /var).
WORK_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lge-exfat.XXXXXX")" && pwd -P)"
IMAGE="$WORK_DIR/exfat.dmg"
MOUNT_POINT="$WORK_DIR/volume"
mkdir -p "$MOUNT_POINT"

cleanup() {
    hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

hdiutil create -size 512m -fs ExFAT -volname LGE-EXFAT -o "$IMAGE" -quiet
hdiutil attach "$IMAGE" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

if ! mount | grep -F " on $MOUNT_POINT (exfat" >/dev/null; then
    echo "exfat-tests: $MOUNT_POINT is not an ExFAT mount" >&2
    exit 1
fi

echo "exfat-tests: running tests matching '$FILTER' with LUNGFISH_EXFAT_TEST_ROOT=$MOUNT_POINT"
cd "$PROJECT_ROOT"
LUNGFISH_EXFAT_TEST_ROOT="$MOUNT_POINT" swift test --skip-update --filter "$FILTER"
