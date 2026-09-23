#!/bin/bash
# fetch-media.sh - Fetch and verify the pinned manual media repo, then place
# its files where the manual build and chapters expect them.
#
# The main repo does not store final chapter illustrations, app screenshots,
# or the large human-genome manual fixtures (hg002-chr20, hg002-long-reads).
# Those live in a separate, private repo (dhoconno/lungfish-manual-media),
# pinned by commit and per-file SHA-256 in docs/user-manual/media.lock. This
# script clones that exact commit into a gitignored cache directory, verifies
# every file's hash, then places the files at the paths chapters and the
# manual build already reference (docs/user-manual/assets/..., docs/user-
# manual/fixtures/hg002-*).
#
# Usage:
#   docs/user-manual/build/scripts/fetch-media.sh
#   docs/user-manual/build/scripts/fetch-media.sh --cache-dir /path/to/cache
#
# Requires: git, python3 (for the sha256 check), a `gh`-authenticated
# session or SSH access if the media repo is private and you are not the
# owner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANUAL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # docs/user-manual
REPO_ROOT="$(cd "$MANUAL_ROOT/../.." && pwd)"
LOCK_FILE="$MANUAL_ROOT/media.lock"
CACHE_DIR="$MANUAL_ROOT/.media-cache"

while [ $# -gt 0 ]; do
    case "$1" in
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --lock-file)
            LOCK_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--cache-dir DIR] [--lock-file FILE]"
            exit 0
            ;;
        *)
            echo "fetch-media.sh: unknown argument: $1" >&2
            exit 64
            ;;
    esac
done

if [ ! -f "$LOCK_FILE" ]; then
    echo "fetch-media.sh: lock file not found at $LOCK_FILE" >&2
    exit 1
fi

REPO_URL="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo'])" "$LOCK_FILE")"
COMMIT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['commit'])" "$LOCK_FILE")"
TAG="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['tag'])" "$LOCK_FILE")"

echo "fetch-media.sh: fetching $REPO_URL @ $TAG ($COMMIT)"

mkdir -p "$CACHE_DIR"
CLONE_DIR="$CACHE_DIR/repo"

if [ -d "$CLONE_DIR/.git" ]; then
    git -C "$CLONE_DIR" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$CLONE_DIR" fetch --quiet origin
else
    rm -rf "$CLONE_DIR"
    git clone --quiet "$REPO_URL" "$CLONE_DIR"
fi
git -C "$CLONE_DIR" checkout --quiet "$COMMIT"

echo "fetch-media.sh: verifying checksums..."
python3 "$SCRIPT_DIR/verify-media-lock.py" "$LOCK_FILE" "$CLONE_DIR"

echo "fetch-media.sh: placing files under $MANUAL_ROOT..."
python3 "$SCRIPT_DIR/place-media-files.py" "$LOCK_FILE" "$CLONE_DIR" "$MANUAL_ROOT"

echo "fetch-media.sh: done. Media placed at their referenced paths under $MANUAL_ROOT."
