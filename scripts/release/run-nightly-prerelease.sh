#!/bin/bash
#
# Run the local 2AM preview-channel release coordinator with the signing defaults used by
# the Lungfish release Mac. The Sparkle private EdDSA key is expected in the
# login Keychain unless --sparkle-ed-key-file is supplied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export LUNGFISH_SPARKLE_PUBLIC_ED_KEY="${LUNGFISH_SPARKLE_PUBLIC_ED_KEY:-FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c=}"

exec /usr/bin/env python3 "${SCRIPT_DIR}/nightly_prerelease_release.py" \
  --repo "${PROJECT_ROOT}" \
  --team-id "29G3WN2GSA" \
  --notary-profile "LungfishNotary" \
  --signing-identity "Developer ID Application: Pathogenuity LLC (29G3WN2GSA)" \
  --sparkle-generate-appcast "${PROJECT_ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --sparkle-publish-release "sparkle-beta" \
  --sparkle-bridge-publish-release "sparkle-alpha" \
  --sparkle-bridge-appcast-filename "appcast-alpha.xml" \
  "$@"
