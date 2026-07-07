#!/usr/bin/env bash
set -euo pipefail

REPAIR=0
if [ "${1:-}" = "--repair" ]; then
    REPAIR=1
    shift
fi

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

ROOT_LOCKFILE="$REPO_ROOT/Package.resolved"
XCODE_LOCKFILE="$REPO_ROOT/Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -f "$ROOT_LOCKFILE" ]; then
    echo "root Package.resolved missing: $ROOT_LOCKFILE" >&2
    exit 66
fi

if [ ! -e "$XCODE_LOCKFILE" ]; then
    printf 'PASS Package.resolved consistency (no Xcode workspace lockfile)\n'
    exit 0
fi

if [ ! -f "$XCODE_LOCKFILE" ]; then
    echo "Xcode Package.resolved path is not a regular file: $XCODE_LOCKFILE" >&2
    exit 66
fi

if cmp -s "$ROOT_LOCKFILE" "$XCODE_LOCKFILE"; then
    printf 'PASS Package.resolved consistency\n'
    exit 0
fi

if [ "$REPAIR" -eq 1 ]; then
    mkdir -p "$(dirname "$XCODE_LOCKFILE")"
    cp "$ROOT_LOCKFILE" "$XCODE_LOCKFILE"
    printf 'PASS Package.resolved consistency (repaired Xcode workspace lockfile)\n'
    exit 0
fi

echo "Package.resolved divergence: root lockfile differs from Xcode workspace lockfile" >&2
echo "  root:  $ROOT_LOCKFILE" >&2
echo "  xcode: $XCODE_LOCKFILE" >&2
echo "Run scripts/check-package-resolved-consistency.sh --repair to align the ignored Xcode lockfile with the tracked root lockfile." >&2
exit 66
