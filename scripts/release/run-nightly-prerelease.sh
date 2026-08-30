#!/bin/bash
# Run the scheduled Preview preparation flow through the supported front door.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_PROFILE="${HOME}/.config/lungfish/release.json"

has_flag() {
  local wanted="$1"
  shift
  local argument
  for argument in "$@"; do
    case "$argument" in
      "$wanted"|"$wanted="*) return 0 ;;
    esac
  done
  return 1
}

DEFAULT_ARGS=(--repo "$PROJECT_ROOT")
XCODE_ASSIGNMENT="$(/usr/bin/env python3 "${SCRIPT_DIR}/release_xcode.py" --shell)"
eval "$XCODE_ASSIGNMENT"
export DEVELOPER_DIR
if ! has_flag --profile "$@"; then
  DEFAULT_ARGS+=(--profile "$DEFAULT_PROFILE")
fi

exec /usr/bin/env python3 "${SCRIPT_DIR}/nightly_prerelease_release.py" \
  "${DEFAULT_ARGS[@]}" \
  "$@"
