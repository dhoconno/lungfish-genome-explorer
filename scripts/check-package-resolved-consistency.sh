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
PBXPROJ="$REPO_ROOT/Lungfish.xcodeproj/project.pbxproj"
RELEASE_PYTHON="${LUNGFISH_RELEASE_PYTHON:-python3}"

# The Xcode project declares its own package requirements (XCRemoteSwiftPackageReference),
# and an exactVersion there that disagrees with the version the root Package.resolved
# actually pinned makes xcodebuild fail resolution ("root depends on X a.b.c"). The
# workspace lockfile is gitignored and reseeded, so this pbxproj drift was the one copy
# of a pin this script did not check: Sparkle 2.9.6 landed in Package.swift while the
# pbxproj still demanded 2.9.1, and only the CI xcodebuild step noticed. --repair does
# not rewrite the pbxproj; drift here is a hard failure to fix in the project file.
if [ -f "$PBXPROJ" ] && [ -f "$ROOT_LOCKFILE" ]; then
    mismatches=$("$RELEASE_PYTHON" - "$PBXPROJ" "$ROOT_LOCKFILE" <<'PYEOF'
import json, re, sys
pbx = open(sys.argv[1]).read()
resolved = {p["identity"].lower(): p["state"].get("version")
            for p in json.load(open(sys.argv[2]))["pins"]}
for m in re.finditer(
    r'repositoryURL\s*=\s*"([^"]+)";\s*requirement\s*=\s*\{\s*kind\s*=\s*exactVersion;\s*version\s*=\s*([0-9.]+);',
    pbx,
):
    url, want = m.group(1), m.group(2)
    identity = url.rstrip("/").split("/")[-1].removesuffix(".git").lower()
    have = resolved.get(identity)
    if have is not None and have != want:
        print(f"{identity}: pbxproj exactVersion {want} != resolved {have}")
PYEOF
)
    if [ -n "$mismatches" ]; then
        echo "FAIL Xcode project package requirements disagree with Package.resolved:" >&2
        echo "$mismatches" >&2
        echo "fix the exactVersion in Lungfish.xcodeproj/project.pbxproj" >&2
        exit 1
    fi
fi

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
