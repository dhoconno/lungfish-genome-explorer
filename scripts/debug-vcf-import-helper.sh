#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <vcf-path> <output-db-path> [import-profile]" >&2
  echo "  import-profile: auto|fast|lowMemory|ultraLowMemory (default: auto)" >&2
  exit 2
fi

VCF_PATH="$1"
OUTPUT_DB_PATH="$2"
IMPORT_PROFILE="${3:-auto}"

if [[ ! -f "$VCF_PATH" ]]; then
  echo "error: VCF not found: $VCF_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEBUG_LOG="/tmp/lungfish-vcf-import-${TIMESTAMP}.log"
EVENT_LOG="/tmp/lungfish-vcf-import-events-${TIMESTAMP}.jsonl"
: > "$DEBUG_LOG"

echo "[debug] repo: $REPO_ROOT"
echo "[debug] vcf: $VCF_PATH"
echo "[debug] output-db: $OUTPUT_DB_PATH"
echo "[debug] profile: $IMPORT_PROFILE"
echo "[debug] debug-log: $DEBUG_LOG"
echo "[debug] event-log: $EVENT_LOG"

SWIFTPM_OPTIONS="$(python3 "$REPO_ROOT/scripts/release/swiftpm_build.py")"
SWIFT_BUILD_ARGS=()
while IFS= read -r option; do SWIFT_BUILD_ARGS+=("$option"); done <<< "$SWIFTPM_OPTIONS"

BINARY_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$REPO_ROOT" --product Lungfish --show-bin-path)/Lungfish"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "[debug] building Lungfish CLI binary..."
  swift build "${SWIFT_BUILD_ARGS[@]}" --package-path "$REPO_ROOT" --product Lungfish >/dev/null
fi
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "error: resolved Lungfish path is not executable after build: $BINARY_PATH" >&2
  exit 1
fi

tail -n +1 -f "$DEBUG_LOG" &
TAIL_PID=$!
cleanup() {
  if kill -0 "$TAIL_PID" >/dev/null 2>&1; then
    kill "$TAIL_PID" >/dev/null 2>&1 || true
    wait "$TAIL_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

set +e
(
  cd "$REPO_ROOT"
  "$BINARY_PATH" \
    --vcf-import-helper \
    --vcf-path "$VCF_PATH" \
    --output-db-path "$OUTPUT_DB_PATH" \
    --source-file "$(basename "$VCF_PATH")" \
    --import-profile "$IMPORT_PROFILE" \
    --debug-log-path "$DEBUG_LOG"
) | tee "$EVENT_LOG"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "[debug] helper exited with status $STATUS" >&2
  exit "$STATUS"
fi

echo "[debug] helper completed successfully"
