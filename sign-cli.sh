#!/bin/bash
# Sign the lungfish-cli binary with virtualization entitlement
# Run this after building with: swift build -c release

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_PATH="${SCRIPT_DIR}/.build/release/lungfish-cli"
ENTITLEMENTS="${SCRIPT_DIR}/lungfish-cli.entitlements"

if [ ! -f "$CLI_PATH" ]; then
    echo "Error: lungfish-cli not found at $CLI_PATH"
    echo "Build first with: swift build -c release"
    exit 1
fi

echo "Signing lungfish-cli with virtualization entitlement..."

# Sign with entitlements (ad-hoc signing with -)
# For distribution, replace "-" with your Developer ID
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$CLI_PATH"

echo "Verifying signature..."
codesign -d --entitlements - "$CLI_PATH" 2>&1 | grep -A5 "com.apple.security.virtualization"

echo ""
echo "Done! lungfish-cli is now signed with com.apple.security.virtualization entitlement."
echo ""
echo "Test with:"
echo "  $CLI_PATH debug container-test"
