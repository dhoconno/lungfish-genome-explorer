#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
MANUAL_DIR="$(cd -- "$SCRIPT_DIR/../.." &>/dev/null && pwd)"
BUILD_DIR="$SCRIPT_DIR/.."

# Chapter illustrations, screenshots, and the two large human fixtures live
# in the pinned manual-media repo (docs/user-manual/media.lock), not in this
# checkout. Fetch and verify them before rendering; this is a fast no-op
# re-verify if they are already present and unchanged.
"$SCRIPT_DIR/fetch-media.sh"

python3 -m pip install --quiet 'mkdocs==1.6.1' 'mkdocs-material==9.5.40'

cd "$BUILD_DIR"
exec mkdocs build --strict --clean
