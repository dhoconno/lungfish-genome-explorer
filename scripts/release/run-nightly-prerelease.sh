#!/bin/bash
# Run the scheduled Preview preparation flow through the supported front door.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_ARGS=(--repo "$PROJECT_ROOT")
XCODE_ASSIGNMENT="$(/usr/bin/env python3 "${SCRIPT_DIR}/release_xcode.py" --shell)"
eval "$XCODE_ASSIGNMENT"
export DEVELOPER_DIR

exec /usr/bin/env python3 "${SCRIPT_DIR}/nightly_prerelease_release.py" \
  "${DEFAULT_ARGS[@]}" \
  "$@"
