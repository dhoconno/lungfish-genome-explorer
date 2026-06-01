#!/bin/bash
# test-surface.sh - Fast inner-loop test runner scoped to a surface.
#
# Runs only the tests matching a name/tag filter so the edit->test cycle is seconds,
# not the ~8 minutes of the full suite. Use the full-suite gate (scripts/full-suite-gate.sh)
# before pushing.
#
# Usage:
#   scripts/test-surface.sh VCF           # name filter (regex over suite/test names)
#   scripts/test-surface.sh TwelveS       # 12S surface
#   scripts/test-surface.sh "Genotype|MHC"
#
# Known surface shortcuts (name filters):
#   vcf|variant   -> VCF/Variant tests
#   12s|twelves   -> TwelveS tests
#   mhc|genotype  -> Genotype/MHC tests
#   sidebar       -> Sidebar tests
#   import        -> import-related tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/test-surface.sh <name-filter>" >&2
    echo "  shortcuts: vcf|variant, 12s|twelves, mhc|genotype, sidebar, import" >&2
    exit 64
fi

# NOTE: `swift test` (SwiftPM) only filters by NAME regex (--filter), not by
# swift-testing @Tag. Tag-based selection works in Xcode's test UI but not via this CLI,
# so this script uses name filters. Tags (Tests/.../TestTags.swift) remain useful metadata.

# Map a few friendly shortcuts to broader name filters; otherwise pass through verbatim.
case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    vcf|variant) FILTER="VCF|Variant" ;;
    12s|twelves) FILTER="TwelveS|Hilo" ;;
    mhc|genotype) FILTER="Genotype|MHC|Haplotype" ;;
    sidebar) FILTER="Sidebar" ;;
    import) FILTER="Import" ;;
    *) FILTER="$1" ;;
esac

echo "Running tests matching /$FILTER/..." >&2
exec swift test --skip-update --filter "$FILTER"
