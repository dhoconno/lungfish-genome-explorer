#!/bin/bash
# measure-build-times.sh - Reproducible build/test timing harness for before/after comparison.
#
# Measures, in order:
#   1. Cold full build (fresh worktree)    - worst case, run first so nothing is warm
#   2. No-op build (warm cache)            - dependency-graph overhead
#   3. Incremental rebuild (one leaf file) - the realistic edit->build cycle
#   4. (optional) Incremental rebuild of the file named by --touch <path>
#   5. (optional) Full test suite          - pass --with-tests to include
#
# Usage:
#   scripts/measure-build-times.sh [label] [--touch <path>] [--with-tests]
#
# Run it alone on a quiet Mac in a fresh worktree. It refuses to run when .build
# exists and never deletes one, because a fresh worktree is the clean state and a
# second run would time a warm tree. The leaf file lives in LungfishOperations,
# which never rebuilds LungfishWorkflow, so --touch <path> adds a second row for a
# file in another module, for example Sources/LungfishWorkflow/Native/MissingToolError.swift.
# A build that fails ends the run with no row, so a short failure never reads as a time.
#
# Writes a markdown row + raw seconds to docs/reports/baselines/<label>-<sha>.md
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

LABEL=""
WITH_TESTS=0
TOUCH_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --with-tests) WITH_TESTS=1 ;;
        --touch)
            shift
            if [ $# -eq 0 ]; then
                echo "measure-build-times: --touch needs a path" >&2
                exit 2
            fi
            TOUCH_FILE="$1"
            ;;
        -*)
            echo "measure-build-times: unknown option $1" >&2
            exit 2
            ;;
        *)
            [ -z "$LABEL" ] && LABEL="$1"
            ;;
    esac
    shift
done
LABEL="${LABEL:-baseline}"

if [ -e .build ] || [ -L .build ]; then
    echo "measure-build-times: .build exists, so the cold build would not be cold. Run in a fresh worktree." >&2
    exit 2
fi
if [ -n "$TOUCH_FILE" ] && [ ! -f "$TOUCH_FILE" ]; then
    echo "measure-build-times: --touch path not found: $TOUCH_FILE" >&2
    exit 2
fi

SHA="$(git rev-parse --short HEAD)"
OUT_DIR="$PROJECT_ROOT/docs/reports/baselines"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${LABEL}-${SHA}.md"

LEAF_FILE="Sources/LungfishOperations/ProjectDeletionPlanner.swift"

# Time a command; echo elapsed whole+fractional seconds to stdout. A command that
# fails ends the run, since exit runs in the $(...) subshell and each call site
# takes || exit 1.
time_cmd() {
    local start end
    start=$(date +%s.%N)
    "$@" >/dev/null 2>&1 || { echo "measure failed: $*" >&2; exit 1; }
    end=$(date +%s.%N)
    awk "BEGIN { printf \"%.1f\", $end - $start }"
}

echo "Measuring build times for $LABEL ($SHA)..." >&2

echo "  [1/5] cold full build (fresh worktree)..." >&2
COLD=$(time_cmd swift build --skip-update) || exit 1

echo "  [2/5] no-op build (warm)..." >&2
NOOP=$(time_cmd swift build --skip-update) || exit 1

echo "  [3/5] incremental rebuild (touch one leaf file)..." >&2
touch "$LEAF_FILE"
INCR=$(time_cmd swift build --skip-update) || exit 1

TOUCHED=""
if [ -n "$TOUCH_FILE" ]; then
    echo "  [4/5] incremental rebuild (touch $TOUCH_FILE)..." >&2
    touch "$TOUCH_FILE"
    TOUCHED=$(time_cmd swift build --skip-update) || exit 1
else
    echo "  [4/5] incremental rebuild of a --touch path: skipped (pass --touch <path> to include)" >&2
fi

TESTS="n/a"
if [ "$WITH_TESTS" -eq 1 ]; then
    echo "  [5/5] full test suite..." >&2
    TESTS=$(time_cmd swift test --skip-update) || exit 1
else
    echo "  [5/5] full test suite: skipped (pass --with-tests to include)" >&2
fi

{
    echo "# Build timing: $LABEL"
    echo ""
    echo "- Commit: \`$SHA\`"
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Host: $(uname -sm), $(sysctl -n hw.ncpu 2>/dev/null) logical cores"
    [ -n "$TOUCH_FILE" ] && echo "- Touched path: \`$TOUCH_FILE\`"
    echo ""
    echo "| Phase | Seconds |"
    echo "| --- | ---: |"
    echo "| Cold full build (fresh worktree) | $COLD |"
    echo "| No-op build (warm) | $NOOP |"
    echo "| Incremental rebuild (1 leaf file) | $INCR |"
    [ -n "$TOUCH_FILE" ] && echo "| Incremental rebuild (touch $TOUCH_FILE) | $TOUCHED |"
    echo "| Full test suite | $TESTS |"
} > "$OUT"

echo "" >&2
echo "Wrote $OUT" >&2
cat "$OUT" >&2
