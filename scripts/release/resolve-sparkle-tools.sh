#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
    printf 'Sparkle tools: %s\n' "$1" >&2
    exit 1
}

has_all_tools() {
    local directory="$1"
    [ -x "${directory}/generate_appcast" ] &&
        [ -x "${directory}/sign_update" ] &&
        [ -x "${directory}/generate_keys" ]
}

emit_tools() {
    local directory
    directory="$(cd "$1" && pwd -P)"
    printf 'SPARKLE_GENERATE_APPCAST=%q\n' "${directory}/generate_appcast"
    printf 'SPARKLE_SIGN_UPDATE=%q\n' "${directory}/sign_update"
    printf 'SPARKLE_GENERATE_KEYS=%q\n' "${directory}/generate_keys"
}

if [ -n "${LUNGFISH_SPARKLE_TOOLS_DIR:-}" ]; then
    has_all_tools "$LUNGFISH_SPARKLE_TOOLS_DIR" ||
        fail "explicit LUNGFISH_SPARKLE_TOOLS_DIR does not contain all three executable tools"
    emit_tools "$LUNGFISH_SPARKLE_TOOLS_DIR"
    exit 0
fi

DEFAULT_TOOLS="${PROJECT_ROOT}/.build/artifacts/sparkle/Sparkle/bin"
if has_all_tools "$DEFAULT_TOOLS"; then
    emit_tools "$DEFAULT_TOOLS"
    exit 0
fi

SCRATCH_ROOT="${LUNGFISH_RELEASE_SCRATCH_ROOT:-/private/var/tmp/lungfish-release-swiftpm}"
case "$SCRATCH_ROOT" in
    /*) ;;
    *) fail "LUNGFISH_RELEASE_SCRATCH_ROOT must be an absolute path" ;;
esac

[ -f "${PROJECT_ROOT}/Package.resolved" ] || fail "Package.resolved is missing"
[ -x /usr/bin/shasum ] || fail "shasum is required to key Sparkle tools to Package.resolved"
LOCK_HASH="$(/usr/bin/shasum -a 256 "${PROJECT_ROOT}/Package.resolved" | /usr/bin/awk '{print $1}')"
case "$LOCK_HASH" in
    *[!0-9a-f]*|'') fail "could not hash Package.resolved" ;;
esac
RESOLUTION_ROOT="${SCRATCH_ROOT}/sparkle-tools/${LOCK_HASH}"
PACKAGE_COPY="${RESOLUTION_ROOT}/package"
BUILD_ROOT="${RESOLUTION_ROOT}/build"
RESOLVED_TOOLS="${BUILD_ROOT}/artifacts/sparkle/Sparkle/bin"

if ! has_all_tools "$RESOLVED_TOOLS"; then
    command -v xcrun >/dev/null 2>&1 || fail "xcrun is required to resolve the pinned Sparkle package"
    [ -f "${PROJECT_ROOT}/Package.swift" ] || fail "Package.swift is missing"

    mkdir -p "$PACKAGE_COPY" "$BUILD_ROOT"
    MANIFEST_PYTHON="${PROJECT_ROOT}/.ci-python/bin/python"
    if [ ! -x "$MANIFEST_PYTHON" ]; then
        MANIFEST_PYTHON="$(command -v python3 || true)"
    fi
    [ -n "$MANIFEST_PYTHON" ] || fail "python3 is required to read the pinned Sparkle package"
    if ! "$MANIFEST_PYTHON" - \
        "${PROJECT_ROOT}/Package.swift" \
        "${PROJECT_ROOT}/Package.resolved" \
        "${PACKAGE_COPY}/Package.swift" \
        "${PACKAGE_COPY}/Package.resolved" <<'PYEOF'
import json
from pathlib import Path
import re
import sys

source_manifest = Path(sys.argv[1]).read_text(encoding="utf-8")
tools_match = re.search(r"^// swift-tools-version:\s*([^\s]+)", source_manifest)
if tools_match is None:
    raise SystemExit("Package.swift has no swift-tools-version")

resolved = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
sparkle = next(
    (pin for pin in resolved.get("pins", []) if pin.get("identity", "").lower() == "sparkle"),
    None,
)
if sparkle is None:
    raise SystemExit("Package.resolved has no Sparkle pin")
location = sparkle.get("location")
version = sparkle.get("state", {}).get("version")
if not isinstance(location, str) or not isinstance(version, str):
    raise SystemExit("Sparkle must be pinned to an exact released version")

manifest = f'''// swift-tools-version: {tools_match.group(1)}
import PackageDescription

let package = Package(
    name: "LungfishSparkleTools",
    dependencies: [
        .package(url: {json.dumps(location)}, exact: {json.dumps(version)})
    ]
)
'''
Path(sys.argv[3]).write_text(manifest, encoding="utf-8")
minimal_lock = {"pins": [sparkle], "version": resolved.get("version", 3)}
Path(sys.argv[4]).write_text(
    json.dumps(minimal_lock, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PYEOF
    then
        fail "could not derive a minimal package from the pinned Sparkle dependency"
    fi
    if ! xcrun swift package resolve \
        --package-path "$PACKAGE_COPY" \
        --scratch-path "$BUILD_ROOT" >&2; then
        fail "SwiftPM could not resolve the pinned Sparkle package"
    fi
fi

has_all_tools "$RESOLVED_TOOLS" ||
    fail "pinned Sparkle package resolved without generate_appcast, sign_update, and generate_keys"
emit_tools "$RESOLVED_TOOLS"
