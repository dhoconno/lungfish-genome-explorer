#!/bin/bash
#
# smoke-test-release-tools.sh
#
# Run tiny smoke tests against the bundled bootstrap tools inside a built
# Lungfish.app bundle.

set -euo pipefail

RELEASE_PYTHON="${LUNGFISH_RELEASE_PYTHON:-python3}"

usage() {
    cat <<'EOF'
Usage: smoke-test-release-tools.sh <Lungfish.app> [--portability-only] [--allowed-swiftpm-fallback ABSOLUTE_PATH]

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABILITY_SCANNER="${SCRIPT_DIR}/release/scan-release-portability.py"
SIGNED_BOOTSTRAP_SMOKE="${SCRIPT_DIR}/release/smoke_signed_bootstrap.py"
ALLOWED_SWIFTPM_FALLBACK="/private/var/tmp/lungfish-release-swiftpm/no-allowed-fallback"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --portability-only)
            PORTABILITY_ONLY=1
            ;;
        --allowed-swiftpm-fallback)
            if [ "$#" -lt 2 ]; then
                echo "--allowed-swiftpm-fallback requires an absolute path" >&2
                exit 64
            fi
            ALLOWED_SWIFTPM_FALLBACK="$2"
            shift
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
MANAGED_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/ManagedTools"
LEGACY_MANAGED_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Contents/Resources/ManagedTools"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
THIRD_PARTY_NOTICES_PATH="$APP_PATH/Contents/Resources/THIRD-PARTY-NOTICES"
CLI_BIN="$APP_PATH/Contents/MacOS/lungfish-cli"
GREP_BIN="/usr/bin/grep"

if [ ! -d "$TOOLS_DIR" ] && [ -d "$LEGACY_TOOLS_DIR" ]; then
    TOOLS_DIR="$LEGACY_TOOLS_DIR"
fi

if [ ! -d "$TOOLS_DIR" ]; then
    echo "tools directory not found: $TOOLS_DIR or $LEGACY_TOOLS_DIR" >&2
    exit 66
fi

if [ ! -d "$MANAGED_TOOLS_DIR" ] && [ -d "$LEGACY_MANAGED_TOOLS_DIR" ]; then
    MANAGED_TOOLS_DIR="$LEGACY_MANAGED_TOOLS_DIR"
fi

if [ ! -d "$MANAGED_TOOLS_DIR" ]; then
    echo "managed tools directory not found: $MANAGED_TOOLS_DIR or $LEGACY_MANAGED_TOOLS_DIR" >&2
    exit 66
fi

if [ ! -x "$GREP_BIN" ]; then
    echo "missing required command: $GREP_BIN" >&2
    exit 69
fi

if [ ! -f "$PORTABILITY_SCANNER" ]; then
    echo "portability scanner missing or not executable" >&2
    exit 69
fi

if [ ! -f "$SIGNED_BOOTSTRAP_SMOKE" ]; then
    echo "signed bootstrap smoke helper missing" >&2
    exit 69
fi

# A release packaged under a stray `umask 077` produces an app that
# is unreadable by any macOS account other than the one that built it. Fail
# the smoke test if any file lacks other-read or any directory lacks
# other-read+execute.
UNREADABLE_FILES=$(/usr/bin/find "$APP_PATH" -type f ! -perm -o=r)
if [ -n "$UNREADABLE_FILES" ]; then
    echo "app bundle contains files without other-read permission (o+r):" >&2
    printf '%s\n' "$UNREADABLE_FILES" >&2
    exit 66
fi

UNTRAVERSABLE_DIRS=$(/usr/bin/find "$APP_PATH" -type d ! -perm -o=rx)
if [ -n "$UNTRAVERSABLE_DIRS" ]; then
    echo "app bundle contains directories without other-read+execute permission (o+rx):" >&2
    printf '%s\n' "$UNTRAVERSABLE_DIRS" >&2
    exit 66
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "Info.plist missing: $INFO_PLIST" >&2
    exit 66
fi

if [ ! -f "$APP_ICON_PATH" ]; then
    echo "app icon missing: $APP_ICON_PATH" >&2
    exit 66
fi

# THIRD-PARTY-NOTICES must be bundled (it ships the GPL-2.0 kernel
# notice/source offer and every compiled-in SwiftPM dependency's license).
if [ ! -f "$THIRD_PARTY_NOTICES_PATH" ]; then
    echo "THIRD-PARTY-NOTICES missing from app bundle: $THIRD_PARTY_NOTICES_PATH" >&2
    exit 66
fi

if ! "$GREP_BIN" -q "GPL-2.0" "$THIRD_PARTY_NOTICES_PATH"; then
    echo "THIRD-PARTY-NOTICES does not mention the bundled GPL-2.0 kernel: $THIRD_PARTY_NOTICES_PATH" >&2
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

# fastp-known-adapters.fasta: the adapters a single-read trim names so fastp guesses none (ruling BIO-PROBES-E).
EXPECTED_ENTRIES=(
    "VERSIONS.txt"
    "fastp-known-adapters.fasta"
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
    if "$GREP_BIN" -F -q -- "$retired_tool" "$TOOLS_DIR/tool-versions.json"; then
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
    if "$GREP_BIN" -F -q -- "$retired_tool" "$TOOLS_DIR/VERSIONS.txt"; then
        echo "version summary still references retired tool: $retired_tool" >&2
        exit 66
    fi
done

if ! "$GREP_BIN" -F -q -- '"name": "micromamba"' "$TOOLS_DIR/tool-versions.json"; then
    echo "tool metadata missing micromamba entry" >&2
    exit 66
fi

if ! "$GREP_BIN" -F -q -- "- micromamba:" "$TOOLS_DIR/VERSIONS.txt"; then
    echo "version summary missing micromamba entry" >&2
    exit 66
fi

LOCK_MANIFEST="$MANAGED_TOOLS_DIR/third-party-tools-lock.json"

if [ ! -f "$LOCK_MANIFEST" ]; then
    echo "dependency manifest missing: $LOCK_MANIFEST" >&2
    exit 66
fi

BOOTSTRAP_VERSION=$("$RELEASE_PYTHON" -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data["bootstrap"]["micromamba"]["version"])
' "$LOCK_MANIFEST")

if [ -z "$BOOTSTRAP_VERSION" ]; then
    echo "dependency manifest missing bootstrap.micromamba.version: $LOCK_MANIFEST" >&2
    exit 66
fi

TOOL_VERSIONS_MICROMAMBA_VERSION=$("$RELEASE_PYTHON" -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for tool in data.get("tools", []):
    if tool.get("name") == "micromamba":
        print(tool.get("version", ""))
        break
' "$TOOLS_DIR/tool-versions.json")

if [ "$TOOL_VERSIONS_MICROMAMBA_VERSION" != "$BOOTSTRAP_VERSION" ]; then
    echo "tool-versions.json micromamba version ($TOOL_VERSIONS_MICROMAMBA_VERSION) does not match manifest bootstrap version ($BOOTSTRAP_VERSION)" >&2
    exit 66
fi

# RELEASE-SMOKE-DOCUMENTS-PROMPT (O81, O150). The checks below run the app's own binaries. Run from a folder under
# the user's Documents, Desktop or Downloads folder, macOS holds each binary on a privacy prompt ("would like to
# access files in your Documents folder") that a remote or scripted click cannot answer. The publish of Preview
# 2026.11.1 waited five hours on it. So the checks run from a copy of the app in a fresh folder outside those
# folders, from a working folder inside that copy, and every step has a time limit. A normal smoke takes about
# four seconds, so the default limit of 60 seconds per check is far above it. The variable below only shortens the
# limit, for the tests.
CHECK_TIMEOUT="${LUNGFISH_RELEASE_SMOKE_CHECK_TIMEOUT_SECONDS:-60}"
case "$CHECK_TIMEOUT" in
    ''|*[!0-9]*|0|0[0-9]*)
        echo "LUNGFISH_RELEASE_SMOKE_CHECK_TIMEOUT_SECONDS must be a whole number of seconds above zero, not '$CHECK_TIMEOUT'" >&2
        exit 64
        ;;
esac
STAGE_TIMEOUT=$((CHECK_TIMEOUT * 2))
STAGE_DIR=""
TMP_DIR=""

cleanup_stage() {
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        cd / 2>/dev/null || true
        /bin/rm -rf "$STAGE_DIR"
    fi
}
trap cleanup_stage EXIT

# bounded_run SECONDS STDOUT_FILE STDERR_FILE COMMAND [ARGUMENT...]
# Runs the command in its own process group and ends the whole group when the time is up. Status 124 means the time
# ran out, 126 means the command could not start, and a signal that ended the command comes back as 128 plus its number.
bounded_run() {
    local seconds="$1" out="$2" err="$3"
    shift 3
    "$RELEASE_PYTHON" -c '
import os, signal, subprocess, sys
seconds, out, err, command = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
with open(out, "wb") as stdout, open(err, "wb") as stderr:
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                   start_new_session=True)
    except OSError as error:
        stderr.write(("cannot run %s: %s\n" % (command[0], error)).encode())
        sys.exit(126)
    try:
        code = process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        for number in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, number)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        sys.exit(124)
    sys.exit(code if code >= 0 else 128 - code)
' "$seconds" "$out" "$err" "$@"
}

report_timeout() {
    local name="$1" seconds="$2"
    printf 'FAIL %s timed out after %s seconds (this step takes a few seconds when nothing holds it)\n' "$name" "$seconds" >&2
    cat >&2 <<'EOF'
macOS may be showing a privacy prompt that a remote or scripted click cannot answer, for example "would like to access files in your Documents folder". The step waits until someone answers that prompt at the Mac.
To fix it, run the publish at the Mac itself, or answer the prompt in System Settings, Privacy and Security, Files and Folders, and then run the command again.
EOF
    exit 124
}

# try_step NAME SECONDS COMMAND...: returns the command's status. A step that runs out of time ends the smoke.
try_step() {
    local name="$1" seconds="$2" rc=0
    shift 2
    bounded_run "$seconds" "$TMP_DIR/${name}.stdout" "$TMP_DIR/${name}.stderr" "$@" || rc=$?
    if [ "$rc" -eq 124 ]; then
        report_timeout "$name" "$seconds"
    fi
    return "$rc"
}

# run_step NAME SECONDS COMMAND...: a step that fails ends the smoke with its output.
run_step() {
    local name="$1" rc=0
    try_step "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL %s exit=%s\n' "$name" "$rc" >&2
        printf -- '--- stdout ---\n' >&2
        sed -n '1,120p' "$TMP_DIR/${name}.stdout" >&2 || true
        printf -- '--- stderr ---\n' >&2
        sed -n '1,160p' "$TMP_DIR/${name}.stderr" >&2 || true
        exit "$rc"
    fi
}

run_test() {
    local name="$1"
    shift
    run_step "$name" "$CHECK_TIMEOUT" "$@"
    printf 'PASS %s\n' "$name"
}

if "$RELEASE_PYTHON" "$PORTABILITY_SCANNER" "$APP_PATH" \
    --allowed-swiftpm-fallback "$ALLOWED_SWIFTPM_FALLBACK"; then
    :
else
    exit $?
fi

if [ "$PORTABILITY_ONLY" -eq 1 ]; then
    exit 0
fi

if [ ! -x "$CLI_BIN" ]; then
    echo "embedded CLI should be bundled and executable: $CLI_BIN" >&2
    exit 66
fi

# resolve_dir DIR prints DIR with every symlink resolved. It prints nothing when DIR does not exist.
resolve_dir() {
    ( cd -P "$1" 2>/dev/null && pwd -P )
}

# protected_folder_holding DIR prints the name of the user's Documents, Desktop or Downloads folder that holds DIR,
# compared by real path so a symlinked folder is caught. It prints nothing when none of them holds DIR.
protected_folder_holding() {
    local candidate="$1" folder resolved
    for folder in Documents Desktop Downloads; do
        resolved=$(resolve_dir "${HOME:-/nonexistent}/$folder" || true)
        [ -n "$resolved" ] || continue
        case "$candidate/" in
            "$resolved"/*)
                printf '%s\n' "$folder"
                return 0
                ;;
        esac
    done
    return 0
}

# code_directory_hash NAME APP sets CDHASH to the CDHash line of the app's signature, or to nothing for an unsigned app.
code_directory_hash() {
    local name="$1" app="$2"
    CDHASH=""
    run_step "$name" "$STAGE_TIMEOUT" /bin/sh -c '/usr/bin/codesign -d --verbose=4 "$1" 2>&1; exit 0' sh "$app"
    CDHASH=$(sed -n 's/^CDHash=//p' "$TMP_DIR/${name}.stdout" | head -n 1)
}

# stage_app_outside_protected_folders copies the app into a fresh folder outside Documents, Desktop and Downloads,
# proves the copy holds the same bytes, and moves the working folder there. The folder is removed on exit, also after
# a failure. The tests set LUNGFISH_RELEASE_CACHE_ROOT to keep the folder in a temporary place.
stage_app_outside_protected_folders() {
    local cache_root="${LUNGFISH_RELEASE_CACHE_ROOT:-/private/var/tmp/lungfish-release-cache}"
    local nearest="$cache_root" resolved_root protected original_hash original_verifies=1 relative
    # Judge the nearest folder that exists first, so a refused folder is never created.
    while [ ! -d "$nearest" ] && [ "$nearest" != "/" ] && [ "$nearest" != "." ]; do
        nearest=$(dirname "$nearest")
    done
    resolved_root=$(resolve_dir "$nearest" || true)
    protected=$(protected_folder_holding "$resolved_root")
    if [ -n "$protected" ]; then
        echo "the smoke folder $cache_root is inside your $protected folder ($resolved_root). The checks run the app's own binaries there, and macOS would hold them on a privacy prompt that a remote or scripted click cannot answer. Set LUNGFISH_RELEASE_CACHE_ROOT to a folder outside Documents, Desktop and Downloads, for example /private/var/tmp/lungfish-release-cache." >&2
        exit 78
    fi
    /bin/mkdir -p "$cache_root"
    resolved_root=$(resolve_dir "$cache_root" || true)
    if [ -z "$resolved_root" ]; then
        echo "cannot create the smoke folder $cache_root. Set LUNGFISH_RELEASE_CACHE_ROOT to a folder you can write outside Documents." >&2
        exit 73
    fi
    STAGE_DIR=$(/usr/bin/mktemp -d "$resolved_root/lungfish-release-smoke.XXXXXX")
    TMP_DIR="$STAGE_DIR/work"
    STAGE_APP="$STAGE_DIR/app/$(basename "$APP_PATH")"
    /bin/mkdir "$TMP_DIR" "$STAGE_DIR/tmp" "$STAGE_DIR/helpers" "$STAGE_DIR/app"

    run_step stage-copy "$STAGE_TIMEOUT" /usr/bin/ditto "$APP_PATH" "$STAGE_APP"
    # A signed app must still verify as a copy, and the copy must carry the same code directory hash. An unsigned
    # candidate has no hash, so the two binaries the checks run are also compared byte for byte.
    try_step stage-verify-original "$STAGE_TIMEOUT" /usr/bin/codesign --verify --deep --strict "$APP_PATH" || original_verifies=0
    if [ "$original_verifies" -eq 1 ]; then
        run_step stage-verify-copy "$STAGE_TIMEOUT" /usr/bin/codesign --verify --deep --strict "$STAGE_APP"
    fi
    code_directory_hash stage-hash-original "$APP_PATH"
    original_hash="$CDHASH"
    code_directory_hash stage-hash-copy "$STAGE_APP"
    if [ "$original_hash" != "$CDHASH" ]; then
        echo "the copy of the app for the smoke has another code directory hash than the original (${original_hash:-none} and ${CDHASH:-none})" >&2
        exit 70
    fi
    for relative in "Contents/MacOS/lungfish-cli" "${TOOLS_DIR#"$APP_PATH"/}/micromamba"; do
        if ! /usr/bin/cmp -s "$APP_PATH/$relative" "$STAGE_APP/$relative"; then
            echo "$relative in the copy of the app differs from the original, so the smoke did not run it" >&2
            exit 70
        fi
    done

    /bin/cp "$SIGNED_BOOTSTRAP_SMOKE" "$STAGE_DIR/helpers/smoke_signed_bootstrap.py"
    RUN_BOOTSTRAP_SMOKE="$STAGE_DIR/helpers/smoke_signed_bootstrap.py"
    RUN_APP="$STAGE_APP"
    RUN_CLI="$STAGE_APP/Contents/MacOS/lungfish-cli"
    RUN_TOOLS_DIR="$STAGE_APP/${TOOLS_DIR#"$APP_PATH"/}"
    export TMPDIR="$STAGE_DIR/tmp"
    cd "$TMP_DIR"
}

stage_app_outside_protected_folders
run_test micromamba "$RUN_TOOLS_DIR/micromamba" --version
run_test lungfish-cli-version "$RUN_CLI" --version
run_test lungfish-cli-tools "$RUN_CLI" version --tools
run_test signed-bootstrap-reconciliation \
    "$RELEASE_PYTHON" "$RUN_BOOTSTRAP_SMOKE" "$RUN_APP"

FASTQ_INPUT="$TMP_DIR/smoke.fastq"
QC_OUTPUT="$TMP_DIR/qc-summary.json"
cat >"$FASTQ_INPUT" <<'EOF'
@smoke-read
ACGT
+
!!!!
EOF

run_test lungfish-cli-qc-summary "$RUN_CLI" fastq qc-summary "$FASTQ_INPUT" --output "$QC_OUTPUT"

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

if ! "$GREP_BIN" -F -q -- "lungfish fastq qc-summary" "$QC_OUTPUT.lungfish-provenance.json"; then
    echo "CLI QC smoke provenance does not identify qc-summary workflow" >&2
    exit 66
fi
