#!/bin/bash
# upload-timeout.sh
#
# REL-05: a fixed 180s timeout applied to every `gh` call (including the DMG
# upload) times out well before a ~167 MB DMG can finish uploading at the
# ~100 KB/s rates this project has recorded in practice. Asset uploads need a
# budget that scales with file size instead of the flat metadata-call budget.
#
# Sourced by build-notarized-dmg.sh; also sourced directly by
# scripts/tests/test_upload_timeout.py via `bash -c` for isolated testing of
# the timeout computation, without pulling in the full release builder.
#
# Not meant to be executed directly.

# github_cli_asset_upload_timeout_seconds <asset-path>
#
# Prints the timeout, in whole seconds, to use for a `gh release
# create|upload` call whose LAST argument is a local asset at <asset-path>.
#
# LUNGFISH_RELEASE_UPLOAD_TIMEOUT_SECONDS overrides the computation entirely,
# for a known-slow link or an artifact whose size does not fit the default
# formula.
#
# Otherwise: max(600, size_bytes / 50_000). At the ~100 KB/s upload rate this
# project has recorded, a 167 MB DMG needs about 1670s (~28 minutes); the
# formula's default divisor of 50,000 bytes/s gives headroom above that for
# a slower link, while the 600s (10 minute) floor keeps small assets (a
# Sparkle appcast, signature file) from getting an unreasonably short budget
# on a bad connection.
github_cli_asset_upload_timeout_seconds() {
    local asset_path="$1"
    if [ -n "${LUNGFISH_RELEASE_UPLOAD_TIMEOUT_SECONDS:-}" ]; then
        printf '%s\n' "$LUNGFISH_RELEASE_UPLOAD_TIMEOUT_SECONDS"
        return
    fi
    local size_bytes
    size_bytes=$(/usr/bin/stat -f %z "$asset_path" 2>/dev/null || echo 0)
    local scaled=$(( size_bytes / 50000 ))
    if [ "$scaled" -lt 600 ]; then
        scaled=600
    fi
    printf '%s\n' "$scaled"
}
