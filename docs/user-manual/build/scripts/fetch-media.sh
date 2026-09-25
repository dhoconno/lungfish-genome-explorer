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
#
# Public builds (Read the Docs) cannot clone the private repo. For them,
# media.lock carries a "publicArchive" entry: a tarball of the files the
# rendered manual shows (screenshots and illustrations, not the fixtures),
# published on the public repo's "manual-media" release. With --public, or
# automatically when READTHEDOCS is set or the clone fails, this script
# downloads that archive, checks its SHA-256, and then verifies and places
# only the lock entries under the archive's prefixes, each against its own
# per-file hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANUAL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # docs/user-manual
REPO_ROOT="$(cd "$MANUAL_ROOT/../.." && pwd)"
LOCK_FILE="$MANUAL_ROOT/media.lock"
CACHE_DIR="$MANUAL_ROOT/.media-cache"
MODE="auto"
if [ -n "${READTHEDOCS:-}" ]; then
    MODE="public"
fi

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
        --public)
            MODE="public"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--cache-dir DIR] [--lock-file FILE] [--public]"
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

fetch_public() {
    local archive_dir="$CACHE_DIR/public"
    local filtered_lock="$CACHE_DIR/public-media.lock"
    local url sha
    url="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['publicArchive']['url'])" "$LOCK_FILE")"
    sha="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['publicArchive']['sha256'])" "$LOCK_FILE")"
    echo "fetch-media.sh: fetching public archive $url"
    mkdir -p "$CACHE_DIR"
    curl -fsSL --retry 3 -o "$CACHE_DIR/public-media.tar.gz" "$url"
    python3 - "$CACHE_DIR/public-media.tar.gz" "$sha" <<'PY'
import hashlib, sys
digest = hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()
if digest != sys.argv[2]:
    sys.exit(f"fetch-media.sh: public archive sha256 mismatch (expected {sys.argv[2]}, got {digest})")
PY
    rm -rf "$archive_dir"
    mkdir -p "$archive_dir"
    tar -xzf "$CACHE_DIR/public-media.tar.gz" -C "$archive_dir"
    python3 - "$LOCK_FILE" "$filtered_lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
prefixes = tuple(lock["publicArchive"]["prefixes"])
lock["files"] = [f for f in lock["files"] if f["path"].startswith(prefixes)]
json.dump(lock, open(sys.argv[2], "w"), indent=2)
print(f"fetch-media.sh: public archive covers {len(lock['files'])} files")
PY
    echo "fetch-media.sh: verifying checksums..."
    python3 "$SCRIPT_DIR/verify-media-lock.py" "$filtered_lock" "$archive_dir"
    echo "fetch-media.sh: placing files under $MANUAL_ROOT..."
    python3 "$SCRIPT_DIR/place-media-files.py" "$filtered_lock" "$archive_dir" "$MANUAL_ROOT"
    echo "fetch-media.sh: done. Public media placed under $MANUAL_ROOT."
}

if [ "$MODE" = "public" ]; then
    fetch_public
    exit 0
fi

echo "fetch-media.sh: fetching $REPO_URL @ $TAG ($COMMIT)"

mkdir -p "$CACHE_DIR"
CLONE_DIR="$CACHE_DIR/repo"

if [ -d "$CLONE_DIR/.git" ]; then
    git -C "$CLONE_DIR" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$CLONE_DIR" fetch --quiet origin
else
    rm -rf "$CLONE_DIR"
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_URL" "$CLONE_DIR"; then
        echo "fetch-media.sh: cannot clone $REPO_URL; falling back to the public archive" >&2
        fetch_public
        exit 0
    fi
fi
git -C "$CLONE_DIR" checkout --quiet "$COMMIT"

echo "fetch-media.sh: verifying checksums..."
python3 "$SCRIPT_DIR/verify-media-lock.py" "$LOCK_FILE" "$CLONE_DIR"

echo "fetch-media.sh: placing files under $MANUAL_ROOT..."
python3 "$SCRIPT_DIR/place-media-files.py" "$LOCK_FILE" "$CLONE_DIR" "$MANUAL_ROOT"

echo "fetch-media.sh: done. Media placed at their referenced paths under $MANUAL_ROOT."
