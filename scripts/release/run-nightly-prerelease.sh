#!/bin/bash
#
# Run the local 2AM preview-channel release coordinator. Machine-specific
# credential names live in the local profile, environment, or explicit flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RELEASE_PROFILE="${HOME}/.config/lungfish/release.env"

if [ -f "$RELEASE_PROFILE" ]; then
  ENV_SIGNING_IDENTITY="${LUNGFISH_SIGNING_IDENTITY:-}"
  ENV_TEAM_ID="${LUNGFISH_TEAM_ID:-}"
  ENV_NOTARY_PROFILE="${LUNGFISH_NOTARY_PROFILE:-}"
  ENV_SPARKLE_ED_KEY_FILE="${LUNGFISH_SPARKLE_ED_KEY_FILE:-}"
  ENV_DEPENDENCY_RECEIPT="${LUNGFISH_DEPENDENCY_RECEIPT:-}"
  # This user-owned, ignored profile contains shell assignments only.
  # shellcheck disable=SC1090
  source "$RELEASE_PROFILE"
  [ -z "$ENV_SIGNING_IDENTITY" ] || LUNGFISH_SIGNING_IDENTITY="$ENV_SIGNING_IDENTITY"
  [ -z "$ENV_TEAM_ID" ] || LUNGFISH_TEAM_ID="$ENV_TEAM_ID"
  [ -z "$ENV_NOTARY_PROFILE" ] || LUNGFISH_NOTARY_PROFILE="$ENV_NOTARY_PROFILE"
  [ -z "$ENV_SPARKLE_ED_KEY_FILE" ] || LUNGFISH_SPARKLE_ED_KEY_FILE="$ENV_SPARKLE_ED_KEY_FILE"
  [ -z "$ENV_DEPENDENCY_RECEIPT" ] || LUNGFISH_DEPENDENCY_RECEIPT="$ENV_DEPENDENCY_RECEIPT"
fi

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
if ! has_flag --team-id "$@" && [ -n "${LUNGFISH_TEAM_ID:-}" ]; then
  DEFAULT_ARGS+=(--team-id "$LUNGFISH_TEAM_ID")
fi
if ! has_flag --notary-profile "$@" && [ -n "${LUNGFISH_NOTARY_PROFILE:-}" ]; then
  DEFAULT_ARGS+=(--notary-profile "$LUNGFISH_NOTARY_PROFILE")
fi
if ! has_flag --signing-identity "$@" && [ -n "${LUNGFISH_SIGNING_IDENTITY:-}" ]; then
  DEFAULT_ARGS+=(--signing-identity "$LUNGFISH_SIGNING_IDENTITY")
fi
if ! has_flag --sparkle-ed-key-file "$@" && [ -n "${LUNGFISH_SPARKLE_ED_KEY_FILE:-}" ]; then
  DEFAULT_ARGS+=(--sparkle-ed-key-file "$LUNGFISH_SPARKLE_ED_KEY_FILE")
fi
if ! has_flag --dependency-receipt "$@" && [ -n "${LUNGFISH_DEPENDENCY_RECEIPT:-}" ]; then
  DEFAULT_ARGS+=(--dependency-receipt "$LUNGFISH_DEPENDENCY_RECEIPT")
fi
if ! has_flag --sparkle-generate-appcast "$@"; then
  SPARKLE_TOOL_ASSIGNMENTS="$("${SCRIPT_DIR}/resolve-sparkle-tools.sh")"
  eval "$SPARKLE_TOOL_ASSIGNMENTS"
  DEFAULT_ARGS+=(--sparkle-generate-appcast "$SPARKLE_GENERATE_APPCAST")
fi
export LUNGFISH_SPARKLE_PUBLIC_ED_KEY="${LUNGFISH_SPARKLE_PUBLIC_ED_KEY:-FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c=}"

exec /usr/bin/env python3 "${SCRIPT_DIR}/nightly_prerelease_release.py" \
  "${DEFAULT_ARGS[@]}" \
  "$@"
