#!/bin/bash
# measure-build-times.sh - Reproducible build/test timing harness for before/after comparison.
#
# Measures, in order:
#   1. No-op build (warm cache)            - dependency-graph overhead
#   2. Incremental rebuild (one leaf file) - the realistic edit->build cycle
#   3. Cold full build (clean .build)      - worst case, e.g. a fresh worktree
#   4. (optional) Full test suite          - pass --with-tests to include
#
# Usage:
#   scripts/measure-build-times.sh [label] [--with-tests]
#
# Writes a markdown row + raw seconds to docs/reports/baselines/<label>-<sha>.md
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

LABEL="${1:-baseline}"
WITH_TESTS=0
for arg in "$@"; do
    [ "$arg" = "--with-tests" ] && WITH_TESTS=1
done

SHA="$(git rev-parse --short HEAD)"
OUT_DIR="$PROJECT_ROOT/docs/reports/baselines"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${LABEL}-${SHA}.md"

LEAF_FILE="Sources/LungfishApp/Services/ProjectDeletionPlanner.swift"

# Time a command; echo elapsed whole+fractional seconds to stdout.
time_cmd() {
    local start end
    start=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    end=$(date +%s.%N)
    awk "BEGIN { printf \"%.1f\", $end - $start }"
}

echo "Measuring build times for $LABEL ($SHA)..." >&2

echo "  [1/4] no-op build (warm)..." >&2
NOOP=$(time_cmd swift build --skip-update)

echo "  [2/4] incremental rebuild (touch one leaf file)..." >&2
touch "$LEAF_FILE"
INCR=$(time_cmd swift build --skip-update)

echo "  [3/4] cold full build (rm -rf .build)..." >&2
rm -rf .build
COLD=$(time_cmd swift build --skip-update)

TESTS="n/a"
if [ "$WITH_TESTS" -eq 1 ]; then
    echo "  [4/4] full test suite..." >&2
    TESTS=$(time_cmd swift test --skip-update)
else
    echo "  [4/4] full test suite: skipped (pass --with-tests to include)" >&2
fi

{
    echo "# Build timing: $LABEL"
    echo ""
    echo "- Commit: \`$SHA\`"
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Host: $(uname -sm), $(sysctl -n hw.ncpu 2>/dev/null) logical cores"
    echo ""
    echo "| Phase | Seconds |"
    echo "| --- | ---: |"
    echo "| No-op build (warm) | $NOOP |"
    echo "| Incremental rebuild (1 leaf file) | $INCR |"
    echo "| Cold full build (clean .build) | $COLD |"
    echo "| Full test suite | $TESTS |"
} > "$OUT"

echo "" >&2
echo "Wrote $OUT" >&2
cat "$OUT" >&2
