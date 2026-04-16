#!/bin/bash
#
# smoke-test-release-tools.sh
#
# Run tiny smoke tests against the bundled native tools inside a built
# Lungfish.app bundle.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: smoke-test-release-tools.sh <Lungfish.app> [--scrubber-db /path/to/human_filter.db]

Verifies that managed core tools such as BBTools and Java are not bundled, then
runs tiny-input smoke tests against the remaining bundled tools and, when a
human-scrubber database is available, against scrub.sh as well.
EOF
}

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 64
fi

APP_PATH="$1"
shift

SCRUBBER_DB="${LUNGFISH_SCRUBBER_DB:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scrubber-db)
            shift
            if [ "$#" -eq 0 ]; then
                echo "missing value for --scrubber-db" >&2
                exit 64
            fi
            SCRUBBER_DB="$1"
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

TOOLS_DIR="$APP_PATH/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"
RG_BIN="$(command -v rg || true)"

if [ ! -d "$TOOLS_DIR" ]; then
    echo "tools directory not found: $TOOLS_DIR" >&2
    exit 66
fi

if [ -z "$RG_BIN" ]; then
    echo "missing required command: rg" >&2
    exit 69
fi

if [ -e "$TOOLS_DIR/bbtools" ]; then
    echo "bbtools should not be bundled: $TOOLS_DIR/bbtools" >&2
    exit 66
fi

if [ -e "$TOOLS_DIR/jre" ]; then
    echo "jre should not be bundled: $TOOLS_DIR/jre" >&2
    exit 66
fi

find_scrubber_db() {
    if [ -n "$SCRUBBER_DB" ] && [ -f "$SCRUBBER_DB" ]; then
        printf '%s\n' "$SCRUBBER_DB"
        return 0
    fi

    local candidate
    for candidate in \
        "$HOME/.lungfish/databases/human-scrubber" \
        "$HOME/Library/Application Support/Lungfish/databases/human-scrubber"
    do
        if [ -d "$candidate" ]; then
            local found
            found=$(find "$candidate" -maxdepth 2 -type f -name 'human_filter.db*' | head -n 1 || true)
            if [ -n "$found" ]; then
                printf '%s\n' "$found"
                return 0
            fi
        fi
    done

    return 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/single.fq" <<'EOF'
@r1
ACGTACGT
+
FFFFFFFF
EOF

cat >"$TMP_DIR/r1.fq" <<'EOF'
@pair1/1
ACGTACGT
+
FFFFFFFF
EOF

cat >"$TMP_DIR/r2.fq" <<'EOF'
@pair1/2
ACGTACGT
+
FFFFFFFF
EOF

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

run_test samtools "$TOOLS_DIR/samtools" --version
run_test seqkit "$TOOLS_DIR/seqkit" version
run_test fastp "$TOOLS_DIR/fastp" --version

if SCRUBBER_DB=$(find_scrubber_db); then
    run_test scrub \
        "$TOOLS_DIR/scrubber/scripts/scrub.sh" \
        -i "$TMP_DIR/single.fq" \
        -o "$TMP_DIR/scrub.fq" \
        -d "$SCRUBBER_DB"
else
    printf 'SKIP scrub (no installed human_filter.db found)\n'
fi
