#!/bin/bash
# exfat-tests.sh - Run tests against ExFAT behaviour.
#
# Most external SSDs ship formatted ExFAT, and LGE must work on them
# (docs/contracts/EXTERNAL-VOLUMES.md). Two modes:
#
#   Real volume (default). Makes a scratch ExFAT disk image, mounts it, and runs the
#   tests that read LUNGFISH_EXFAT_TEST_ROOT (their names contain "ExFAT"), then
#   detaches and deletes the image.
#
#   --simulate. Runs the publication and storage suites on the normal disk with
#   LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1, so every rename with RENAME_EXCL or
#   RENAME_SWAP that goes through PortableRename takes its ExFAT fallback.
#
# Usage:
#   scripts/testing/exfat-tests.sh                    # real ExFAT image, tests named *ExFAT*
#   scripts/testing/exfat-tests.sh "Analyses"         # real ExFAT image, another name filter
#   scripts/testing/exfat-tests.sh --simulate         # every rename-touching suite, simulated
#   scripts/testing/exfat-tests.sh --simulate "Mapping"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

SIMULATED_SUITES="PortableRename|AnalysesFolder|AnalysisRunRecord|DurableAtomicFileStore|OwnedWorkDirectory|ProjectTempDirectory|ONTGenotypeWorkbook|Provenance|ProjectOperationHistory|ProjectStorageCleanup|GenotypeReviewableRowCatalog|MappingViewerBundle|GenotypingCleanupJournal|FullLengthONTMHC|PrimerAnalysis"

if [ "${1:-}" = "--simulate" ]; then
    FILTER="${2:-$SIMULATED_SUITES}"
    echo "exfat-tests: running tests matching '$FILTER' with LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1"
    LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1 swift test --skip-update --filter "$FILTER"
    exit
fi

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
LUNGFISH_EXFAT_TEST_ROOT="$MOUNT_POINT" swift test --skip-update --filter "$FILTER"
