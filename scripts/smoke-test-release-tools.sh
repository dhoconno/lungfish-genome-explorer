#!/bin/bash
#
# smoke-test-release-tools.sh
#
# Run tiny smoke tests against the bundled bootstrap tools inside a built
# Lungfish.app bundle.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: smoke-test-release-tools.sh <Lungfish.app> [--portability-only]

Verifies that only micromamba remains bundled, scans the packaged app for
leaked build/Homebrew paths, and optionally runs tiny smoke tests against the
bootstrap binary and embedded CLI.
EOF
}

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 64
fi

APP_PATH="$1"
shift
PORTABILITY_ONLY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --portability-only)
            PORTABILITY_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 64
            ;;
    esac
    shift
done

WORKFLOW_BUNDLE_DIR="$APP_PATH/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle"
TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Tools"
LEGACY_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Contents/Resources/Tools"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
CLI_BIN="$APP_PATH/Contents/MacOS/lungfish-cli"
RG_BIN="$(command -v rg || true)"

if [ ! -d "$TOOLS_DIR" ] && [ -d "$LEGACY_TOOLS_DIR" ]; then
    TOOLS_DIR="$LEGACY_TOOLS_DIR"
fi

if [ ! -d "$TOOLS_DIR" ]; then
    echo "tools directory not found: $TOOLS_DIR or $LEGACY_TOOLS_DIR" >&2
    exit 66
fi

if [ -z "$RG_BIN" ]; then
    echo "missing required command: rg" >&2
    exit 69
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "Info.plist missing: $INFO_PLIST" >&2
    exit 66
fi

if [ ! -f "$APP_ICON_PATH" ]; then
    echo "app icon missing: $APP_ICON_PATH" >&2
    exit 66
fi

if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$INFO_PLIST" 2>/dev/null || true)" != "AppIcon" ]; then
    echo "CFBundleIconFile should be AppIcon in $INFO_PLIST" >&2
    exit 66
fi

if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$INFO_PLIST" 2>/dev/null || true)" != "AppIcon" ]; then
    echo "CFBundleIconName should be AppIcon in $INFO_PLIST" >&2
    exit 66
fi

if [ ! -x "$TOOLS_DIR/micromamba" ]; then
    echo "micromamba should be bundled and executable: $TOOLS_DIR/micromamba" >&2
    exit 66
fi

for retired_path in \
    "$TOOLS_DIR/bbtools" \
    "$TOOLS_DIR/jre" \
    "$TOOLS_DIR/fastp" \
    "$TOOLS_DIR/seqkit" \
    "$TOOLS_DIR/samtools" \
    "$TOOLS_DIR/bcftools" \
    "$TOOLS_DIR/bgzip" \
    "$TOOLS_DIR/tabix" \
    "$TOOLS_DIR/bedToBigBed" \
    "$TOOLS_DIR/bedGraphToBigWig" \
    "$TOOLS_DIR/htslib" \
    "$TOOLS_DIR/vsearch" \
    "$TOOLS_DIR/cutadapt" \
    "$TOOLS_DIR/pigz" \
    "$TOOLS_DIR/sra-human-scrubber" \
    "$TOOLS_DIR/sra-tools" \
    "$TOOLS_DIR/scrubber/bin/aligns_to"
do
    if [ -e "$retired_path" ]; then
        echo "retired tool should not be bundled: $retired_path" >&2
        exit 66
    fi
done

if [ ! -f "$TOOLS_DIR/tool-versions.json" ]; then
    echo "tool manifest missing: $TOOLS_DIR/tool-versions.json" >&2
    exit 66
fi

if [ ! -f "$TOOLS_DIR/VERSIONS.txt" ]; then
    echo "version summary missing: $TOOLS_DIR/VERSIONS.txt" >&2
    exit 66
fi

EXPECTED_ENTRIES=(
    "VERSIONS.txt"
    "micromamba"
    "tool-versions.json"
)

while IFS= read -r relative_path; do
    if [ -z "$relative_path" ]; then
        continue
    fi

    if ! printf '%s\n' "${EXPECTED_ENTRIES[@]}" | grep -Fx -- "$relative_path" >/dev/null 2>&1; then
        echo "unexpected bundled tool entry: $TOOLS_DIR/$relative_path" >&2
        exit 66
    fi
done < <(/usr/bin/find "$TOOLS_DIR" -mindepth 1 -print | sed "s#^$TOOLS_DIR/##" | sort)

for retired_tool in \
    '"name": "samtools"' \
    '"name": "bcftools"' \
    '"name": "htslib"' \
    '"name": "ucsc-tools"' \
    '"name": "seqkit"' \
    '"name": "cutadapt"' \
    '"name": "vsearch"' \
    '"name": "pigz"' \
    '"name": "sra-human-scrubber"' \
    '"name": "sra-tools"'
do
    if "$RG_BIN" -F -q "$retired_tool" "$TOOLS_DIR/tool-versions.json"; then
        echo "tool metadata still references retired tool: $retired_tool" >&2
        exit 66
    fi
done

for retired_tool in \
    samtools \
    bcftools \
    tabix \
    htslib \
    seqkit \
    cutadapt \
    vsearch \
    pigz \
    bedToBigBed \
    bedGraphToBigWig \
    fasterq-dump \
    prefetch \
    aligns_to
do
    if "$RG_BIN" -F -q "$retired_tool" "$TOOLS_DIR/VERSIONS.txt"; then
        echo "version summary still references retired tool: $retired_tool" >&2
        exit 66
    fi
done

if ! "$RG_BIN" -F -q '"name": "micromamba"' "$TOOLS_DIR/tool-versions.json"; then
    echo "tool metadata missing micromamba entry" >&2
    exit 66
fi

if ! "$RG_BIN" -F -q -- "- micromamba:" "$TOOLS_DIR/VERSIONS.txt"; then
    echo "version summary missing micromamba entry" >&2
    exit 66
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

run_test() {
    local name="$1"
    shift

    if "$@" >"$TMP_DIR/${name}.stdout" 2>"$TMP_DIR/${name}.stderr"; then
        printf 'PASS %s\n' "$name"
    else
        local rc=$?
        printf 'FAIL %s exit=%s\n' "$name" "$rc" >&2
        printf -- '--- stdout ---\n' >&2
        sed -n '1,120p' "$TMP_DIR/${name}.stdout" >&2 || true
        printf -- '--- stderr ---\n' >&2
        sed -n '1,160p' "$TMP_DIR/${name}.stderr" >&2 || true
        exit "$rc"
    fi
}

run_portability_scan() {
    local leak_patterns=(
        "/Users/dho"
        ".build/xcode-cli-release"
        "/opt/homebrew"
        "/opt/homebrew/Cellar"
        "/usr/local/Cellar"
        "/usr/local/Homebrew"
    )

    local pattern
    for pattern in "${leak_patterns[@]}"; do
        if "$RG_BIN" -a -n --fixed-strings "$pattern" "$APP_PATH" >"$TMP_DIR/portability-scan.stderr" 2>&1; then
            printf 'FAIL portability leak=%s\n' "$pattern" >&2
            sed -n '1,120p' "$TMP_DIR/portability-scan.stderr" >&2 || true
            exit 1
        fi
    done

    printf 'PASS portability\n'
}

run_portability_scan

if [ "$PORTABILITY_ONLY" -eq 1 ]; then
    exit 0
fi

if [ ! -x "$CLI_BIN" ]; then
    echo "embedded CLI should be bundled and executable: $CLI_BIN" >&2
    exit 66
fi

run_test micromamba "$TOOLS_DIR/micromamba" --version
run_test lungfish-cli-version "$CLI_BIN" --version
run_test lungfish-cli-tools "$CLI_BIN" version --tools

FASTQ_INPUT="$TMP_DIR/smoke.fastq"
QC_OUTPUT="$TMP_DIR/qc-summary.json"
cat >"$FASTQ_INPUT" <<'EOF'
@smoke-read
ACGT
+
!!!!
EOF

run_test lungfish-cli-qc-summary "$CLI_BIN" fastq qc-summary "$FASTQ_INPUT" --output "$QC_OUTPUT"

if [ ! -s "$QC_OUTPUT" ]; then
    echo "CLI QC smoke output missing or empty: $QC_OUTPUT" >&2
    exit 66
fi

if [ ! -s "$QC_OUTPUT.lungfish-provenance.json" ]; then
    echo "CLI QC smoke file provenance missing or empty: $QC_OUTPUT.lungfish-provenance.json" >&2
    exit 66
fi

if [ ! -s "$TMP_DIR/.lungfish-provenance.json" ]; then
    echo "CLI QC smoke directory provenance missing or empty: $TMP_DIR/.lungfish-provenance.json" >&2
    exit 66
fi

if ! "$RG_BIN" -F -q "lungfish fastq qc-summary" "$QC_OUTPUT.lungfish-provenance.json"; then
    echo "CLI QC smoke provenance does not identify qc-summary workflow" >&2
    exit 66
fi
