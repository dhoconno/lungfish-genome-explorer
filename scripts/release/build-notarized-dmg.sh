#!/bin/bash
#
# build-notarized-dmg.sh
#
# Create a clean Apple Silicon Lungfish release archive, embed the CLI inside the
# app bundle, notarize the app, wrap it in a DMG, notarize the DMG, and record
# release metadata for reproducibility.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-notarized-dmg.sh [--package-only | --resume-candidate RECEIPT] [--signing-identity "Developer ID Application: Example (TEAMID)" --team-id TEAMID --notary-profile PROFILE] [options]

Required for signing completion:
  --signing-identity  Developer ID Application identity used for codesign
  --team-id           Apple Developer Team ID
  --notary-profile    Keychain profile configured for xcrun notarytool

Optional:
  --package-only      Build and verify an unsigned reusable candidate without credentials
  --resume-candidate RECEIPT
                      Verify and sign the exact candidate bound by RECEIPT without rebuilding
  --describe-channel preview|stable
                      Print the contract-backed channel JSON and exit
  --scratch-path      Explicit canonical SwiftPM scratch path for packaging;
                      must match the configured root/repository key/commit
  --archive-path      Archive output path (default: build/Release/Lungfish.xcarchive)
  --release-dir       Release directory (default: build/Release)
  --derived-data-path DerivedData path for the Xcode archive (default: <project-root>/.build/release-derived-data)
  --remote NAME      Selected Git remote used for identity and tag checks (default: origin)
  --github-repository OWNER/REPO
                      Require the selected remote to identify this GitHub repository
  --reuse-archive     Retired; use --resume-candidate RECEIPT
  --reuse-built-cli   Retired; use --resume-candidate RECEIPT
  --github-release-tag TAG
                      Upload the notarized DMG to this versioned GitHub release tag with gh
  --recover-existing-release
                      Resume the named release only after tag, HEAD, and GitHub target identity checks
  --sparkle-public-ed-key KEY
                      Sparkle public EdDSA key embedded in the app (default: LUNGFISH_SPARKLE_PUBLIC_ED_KEY)
  --sparkle-generate-appcast PATH
                      Sparkle generate_appcast tool path. When set, update the selected channel's appcast after DMG notarization
  --sparkle-ed-key-file PATH
                      Private Sparkle EdDSA key file passed to generate_appcast instead of using the Keychain
  --sparkle-appcast-dir PATH
                      Local appcast working directory (default: <release-dir>/sparkle-appcast)
  --sparkle-appcast-filename NAME
                      Override the contract-selected appcast asset filename
  --sparkle-download-url-prefix URL
                      URL prefix for versioned DMG downloads (default: GitHub release v<version>)
  --sparkle-publish-release TAG
                      Upload the appcast and release notes to this GitHub release tag with gh
  --sparkle-bridge-publish-release TAG
                      Also upload the generated appcast to a legacy Sparkle feed release
  --sparkle-bridge-appcast-filename NAME
                      Override the contract-selected legacy bridge appcast filename
  --channel preview|stable
                      Release channel (default: preview). Application identity,
                      feeds, prerelease status, and legacy bridge defaults are
                      loaded from config/release-contract.json
  --prune-prereleases
                      After successful remote publishing, delete old prerelease GitHub Release records while preserving git tags
  --prune-prereleases-keep COUNT
                      Keep this many newest preview release records in the current version scheme (default: 10)
  --defer-remote-publish
                      Build, notarize, and generate appcast files without running gh uploads

The archive step writes an Xcode timing summary to stdout and stores an
archive result bundle under <release-dir>/logs/archive.xcresult.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$PROJECT_ROOT"
PRERELEASE_PRUNE_SCRIPT="${PROJECT_ROOT}/scripts/release/prune-github-prereleases.py"
RELEASE_CONTRACT_SCRIPT="${PROJECT_ROOT}/scripts/release/release_contract.py"
RELEASE_DOCTOR_SCRIPT="${PROJECT_ROOT}/scripts/release/release-doctor.py"
SPARKLE_BUILD_GATE_SCRIPT="${PROJECT_ROOT}/scripts/release/check-sparkle-build-number.py"
RELEASE_TARGET_SECURITY_SCRIPT="${PROJECT_ROOT}/scripts/release/release_target_security.py"
RELEASE_REPOSITORY_SCRIPT="${PROJECT_ROOT}/scripts/release/release_repository.py"
RELEASE_XCODE_SCRIPT="${PROJECT_ROOT}/scripts/release/release_xcode.py"
CANDIDATE_RECEIPT_SCRIPT="${PROJECT_ROOT}/scripts/release/release-candidate-receipt.py"

SIGNING_IDENTITY=""
TEAM_ID=""
NOTARY_PROFILE=""
SCRATCH_PATH=""
SCRATCH_PATH_EXPLICIT=0
RELEASE_DIR="${PROJECT_ROOT}/build/Release"
ARCHIVE_PATH="${RELEASE_DIR}/Lungfish.xcarchive"
DERIVED_DATA_PATH=""
REUSE_ARCHIVE=0
REUSE_BUILT_CLI=0
PACKAGE_ONLY=0
RESUME_CANDIDATE=""
SPARKLE_PUBLIC_ED_KEY="${LUNGFISH_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"
SPARKLE_GENERATE_APPCAST_EXPLICIT=0
SPARKLE_ED_KEY_FILE_EXPLICIT=0
SPARKLE_APPCAST_DIR=""
CHANNEL="preview"
SHOW_HELP=0
DESCRIBE_CHANNEL=""
SPARKLE_APPCAST_FILENAME_EXPLICIT=0
SPARKLE_PUBLISH_RELEASE_EXPLICIT=0
SPARKLE_BRIDGE_PUBLISH_RELEASE_EXPLICIT=0
SPARKLE_BRIDGE_APPCAST_FILENAME_EXPLICIT=0
SPARKLE_APPCAST_FILENAME=""
SPARKLE_BRIDGE_PUBLISH_RELEASE=""
SPARKLE_BRIDGE_APPCAST_FILENAME=""
SPARKLE_DOWNLOAD_URL_PREFIX=""
SPARKLE_PUBLISH_RELEASE=""
SPARKLE_RELEASE_NOTES=""
SPARKLE_BUILD_NUMBER="${LUNGFISH_BUILD_NUMBER:-}"
SPARKLE_FEED_URL=""
GITHUB_RELEASE_TAG=""
RECOVER_EXISTING_RELEASE=0
DEFER_REMOTE_PUBLISH=0
PRERELEASE_PRUNE_ENABLED=0
PRERELEASE_PRUNE_KEEP=10
PRERELEASE_PRUNE_REPORT_PATH=""
GIT_REMOTE="origin"
GITHUB_REPOSITORY=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --signing-identity)
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --scratch-path)
            SCRATCH_PATH="$2"
            SCRATCH_PATH_EXPLICIT=1
            shift 2
            ;;
        --package-only)
            PACKAGE_ONLY=1
            shift
            ;;
        --resume-candidate)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --resume-candidate" >&2
                exit 64
            fi
            RESUME_CANDIDATE="$2"
            shift 2
            ;;
        --archive-path)
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --release-dir)
            RELEASE_DIR="$2"
            shift 2
            ;;
        --derived-data-path)
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --remote)
            GIT_REMOTE="$2"
            shift 2
            ;;
        --github-repository)
            GITHUB_REPOSITORY="$2"
            shift 2
            ;;
        --reuse-archive)
            REUSE_ARCHIVE=1
            shift
            ;;
        --reuse-built-cli)
            REUSE_BUILT_CLI=1
            shift
            ;;
        --github-release-tag)
            GITHUB_RELEASE_TAG="$2"
            shift 2
            ;;
        --recover-existing-release)
            RECOVER_EXISTING_RELEASE=1
            shift
            ;;
        --sparkle-public-ed-key)
            SPARKLE_PUBLIC_ED_KEY="$2"
            shift 2
            ;;
        --sparkle-generate-appcast)
            SPARKLE_GENERATE_APPCAST="$2"
            SPARKLE_GENERATE_APPCAST_EXPLICIT=1
            shift 2
            ;;
        --sparkle-ed-key-file)
            SPARKLE_ED_KEY_FILE="$2"
            SPARKLE_ED_KEY_FILE_EXPLICIT=1
            shift 2
            ;;
        --sparkle-appcast-dir)
            SPARKLE_APPCAST_DIR="$2"
            shift 2
            ;;
        --channel)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --channel" >&2
                exit 64
            fi
            CHANNEL="$2"
            shift 2
            ;;
        --describe-channel)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --describe-channel" >&2
                exit 64
            fi
            DESCRIBE_CHANNEL="$2"
            shift 2
            ;;
        --sparkle-appcast-filename)
            SPARKLE_APPCAST_FILENAME="$2"
            SPARKLE_APPCAST_FILENAME_EXPLICIT=1
            shift 2
            ;;
        --sparkle-download-url-prefix)
            SPARKLE_DOWNLOAD_URL_PREFIX="$2"
            shift 2
            ;;
        --sparkle-publish-release)
            SPARKLE_PUBLISH_RELEASE="$2"
            SPARKLE_PUBLISH_RELEASE_EXPLICIT=1
            shift 2
            ;;
        --sparkle-bridge-publish-release)
            SPARKLE_BRIDGE_PUBLISH_RELEASE="$2"
            SPARKLE_BRIDGE_PUBLISH_RELEASE_EXPLICIT=1
            shift 2
            ;;
        --sparkle-bridge-appcast-filename)
            SPARKLE_BRIDGE_APPCAST_FILENAME="$2"
            SPARKLE_BRIDGE_APPCAST_FILENAME_EXPLICIT=1
            shift 2
            ;;
        --prune-prereleases)
            PRERELEASE_PRUNE_ENABLED=1
            shift
            ;;
        --prune-prereleases-keep)
            PRERELEASE_PRUNE_KEEP="$2"
            shift 2
            ;;
        --defer-remote-publish)
            DEFER_REMOTE_PUBLISH=1
            shift
            ;;
        --sparkle-release-notes)
            SPARKLE_RELEASE_NOTES="$2"
            shift 2
            ;;
        -h|--help)
            SHOW_HELP=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
    case "$CHANNEL" in
        preview|stable) ;;
        *)
            echo "invalid --channel: ${CHANNEL} (expected preview or stable)" >&2
            exit 64
            ;;
    esac
    usage
    printf '\nContract-selected defaults for %s:\n' "$CHANNEL"
    python3 "$RELEASE_CONTRACT_SCRIPT" describe --channel "$CHANNEL"
    exit 0
fi

if [ -n "$DESCRIBE_CHANNEL" ]; then
    case "$DESCRIBE_CHANNEL" in
        preview|stable) ;;
        *)
            echo "invalid --channel: ${DESCRIBE_CHANNEL} (expected preview or stable)" >&2
            exit 64
            ;;
    esac
    exec python3 "$RELEASE_CONTRACT_SCRIPT" describe --channel "$DESCRIBE_CHANNEL"
fi

if [ "$PACKAGE_ONLY" -eq 0 ]; then
    if ! [[ "${LUNGFISH_RELEASE_COORDINATOR_CAPABILITY:-}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "credentialed release operations must be invoked through scripts/release/release.py" >&2
        exit 64
    fi
    unset LUNGFISH_RELEASE_COORDINATOR_CAPABILITY
fi

if ! channel_contract_output=$(python3 "$RELEASE_CONTRACT_SCRIPT" shell --channel "$CHANNEL"); then
    case "$CHANNEL" in
        preview|stable)
            echo "failed to load release contract for channel: ${CHANNEL}" >&2
            ;;
        *)
            echo "invalid --channel: ${CHANNEL} (expected preview or stable)" >&2
            ;;
    esac
    exit 64
fi

XCODE_ASSIGNMENT=$(python3 "$RELEASE_XCODE_SCRIPT" --shell)
eval "$XCODE_ASSIGNMENT"
export DEVELOPER_DIR

CONTRACT_SPARKLE_APPCAST_FILENAME=""
CONTRACT_SPARKLE_PUBLISH_RELEASE=""
CONTRACT_SPARKLE_BRIDGE_PUBLISH_RELEASE=""
CONTRACT_SPARKLE_BRIDGE_APPCAST_FILENAME=""
PREVIEW_SPARKLE_RELEASE=""
PREVIEW_APPCAST_FILENAME=""
PREVIEW_LEGACY_SPARKLE_RELEASE=""
PREVIEW_LEGACY_APPCAST_FILENAME=""
while IFS='=' read -r contract_key contract_value; do
    case "$contract_key" in
        APP_BUNDLE_FILENAME) APP_BUNDLE_FILENAME="$contract_value" ;;
        APP_DISPLAY_NAME) APP_DISPLAY_NAME="$contract_value" ;;
        APP_SHORT_NAME) APP_SHORT_NAME="$contract_value" ;;
        APP_BUNDLE_IDENTIFIER) APP_BUNDLE_IDENTIFIER="$contract_value" ;;
        RELEASE_CHANNEL) RELEASE_CHANNEL="$contract_value" ;;
        SPARKLE_PUBLISH_RELEASE) CONTRACT_SPARKLE_PUBLISH_RELEASE="$contract_value" ;;
        SPARKLE_APPCAST_FILENAME) CONTRACT_SPARKLE_APPCAST_FILENAME="$contract_value" ;;
        GITHUB_PRERELEASE) GITHUB_PRERELEASE="$contract_value" ;;
        DMG_VOLUME_NAME) DMG_VOLUME_NAME="$contract_value" ;;
        SPARKLE_BRIDGE_PUBLISH_RELEASE) CONTRACT_SPARKLE_BRIDGE_PUBLISH_RELEASE="$contract_value" ;;
        SPARKLE_BRIDGE_APPCAST_FILENAME) CONTRACT_SPARKLE_BRIDGE_APPCAST_FILENAME="$contract_value" ;;
        PREVIEW_SPARKLE_RELEASE) PREVIEW_SPARKLE_RELEASE="$contract_value" ;;
        PREVIEW_APPCAST_FILENAME) PREVIEW_APPCAST_FILENAME="$contract_value" ;;
        PREVIEW_LEGACY_SPARKLE_RELEASE) PREVIEW_LEGACY_SPARKLE_RELEASE="$contract_value" ;;
        PREVIEW_LEGACY_APPCAST_FILENAME) PREVIEW_LEGACY_APPCAST_FILENAME="$contract_value" ;;
        *)
            echo "unexpected release contract key: ${contract_key}" >&2
            exit 64
            ;;
    esac
done <<< "$channel_contract_output"

for required_contract_value in \
    "$APP_BUNDLE_FILENAME" "$APP_DISPLAY_NAME" "$APP_SHORT_NAME" \
    "$APP_BUNDLE_IDENTIFIER" "$RELEASE_CHANNEL" "$CONTRACT_SPARKLE_PUBLISH_RELEASE" \
    "$CONTRACT_SPARKLE_APPCAST_FILENAME" "$GITHUB_PRERELEASE" "$DMG_VOLUME_NAME" \
    "$PREVIEW_SPARKLE_RELEASE" "$PREVIEW_APPCAST_FILENAME"; do
    if [ -z "$required_contract_value" ]; then
        echo "release contract query omitted a required channel value" >&2
        exit 64
    fi
done
if [ -z "$PREVIEW_LEGACY_SPARKLE_RELEASE" ] \
    || [ -z "$PREVIEW_LEGACY_APPCAST_FILENAME" ]; then
    echo "release contract omitted the legacy alpha Sparkle floor" >&2
    exit 64
fi
if [ "$RELEASE_CHANNEL" != "$CHANNEL" ]; then
    echo "release contract channel mismatch: expected ${CHANNEL}, found ${RELEASE_CHANNEL}" >&2
    exit 64
fi
case "$GITHUB_PRERELEASE" in
    true|false) ;;
    *)
        echo "invalid githubPrerelease value in release contract: ${GITHUB_PRERELEASE}" >&2
        exit 64
        ;;
esac
if [ "$SPARKLE_APPCAST_FILENAME_EXPLICIT" -eq 0 ]; then
    SPARKLE_APPCAST_FILENAME="$CONTRACT_SPARKLE_APPCAST_FILENAME"
fi
if [ "$SPARKLE_PUBLISH_RELEASE_EXPLICIT" -eq 0 ]; then
    SPARKLE_PUBLISH_RELEASE="$CONTRACT_SPARKLE_PUBLISH_RELEASE"
fi
if [ "$SPARKLE_BRIDGE_PUBLISH_RELEASE_EXPLICIT" -eq 0 ]; then
    SPARKLE_BRIDGE_PUBLISH_RELEASE="$CONTRACT_SPARKLE_BRIDGE_PUBLISH_RELEASE"
fi
if [ "$SPARKLE_BRIDGE_APPCAST_FILENAME_EXPLICIT" -eq 0 ]; then
    SPARKLE_BRIDGE_APPCAST_FILENAME="$CONTRACT_SPARKLE_BRIDGE_APPCAST_FILENAME"
fi

case "$CHANNEL" in
    preview|stable) ;;
    *)
        echo "invalid --channel: ${CHANNEL} (expected preview or stable)" >&2
        exit 64
        ;;
esac
if [ "$REUSE_ARCHIVE" -eq 1 ] || [ "$REUSE_BUILT_CLI" -eq 1 ]; then
    echo "--reuse-archive and --reuse-built-cli are retired; use --resume-candidate RECEIPT" >&2
    exit 64
fi
if [ "$PACKAGE_ONLY" -eq 1 ] && [ -n "$RESUME_CANDIDATE" ]; then
    echo "--package-only and --resume-candidate are mutually exclusive" >&2
    exit 64
fi
if [ -n "$RESUME_CANDIDATE" ] && [ "$SCRATCH_PATH_EXPLICIT" -eq 1 ]; then
    echo "--resume-candidate derives its scratch identity from the verified receipt" >&2
    exit 64
fi
if [ "$PACKAGE_ONLY" -eq 1 ]; then
    if [ -n "$SIGNING_IDENTITY" ] || [ -n "$TEAM_ID" ] || [ -n "$NOTARY_PROFILE" ] \
        || [ -n "$GITHUB_RELEASE_TAG" ] || [ "$RECOVER_EXISTING_RELEASE" -eq 1 ] \
        || [ "$SPARKLE_GENERATE_APPCAST_EXPLICIT" -eq 1 ] \
        || [ "$SPARKLE_ED_KEY_FILE_EXPLICIT" -eq 1 ] \
        || [ "$SPARKLE_PUBLISH_RELEASE_EXPLICIT" -eq 1 ] \
        || [ "$SPARKLE_BRIDGE_PUBLISH_RELEASE_EXPLICIT" -eq 1 ] \
        || [ "$PRERELEASE_PRUNE_ENABLED" -eq 1 ]; then
        echo "--package-only cannot accept credential, signing, notarization, or publication options" >&2
        exit 64
    fi
    # Ambient release-machine credential configuration is irrelevant to and
    # must never be inspected or executed by package-only work.
    SPARKLE_GENERATE_APPCAST=""
    SPARKLE_ED_KEY_FILE=""
elif [ -z "$SIGNING_IDENTITY" ] || [ -z "$TEAM_ID" ] || [ -z "$NOTARY_PROFILE" ]; then
    usage >&2
    exit 64
fi
if [ "$CHANNEL" = "stable" ] \
    && { [ "$SPARKLE_BRIDGE_PUBLISH_RELEASE_EXPLICIT" -eq 1 ] \
        || [ "$SPARKLE_BRIDGE_APPCAST_FILENAME_EXPLICIT" -eq 1 ]; }; then
    echo "stable channel does not support a legacy preview-feed bridge" >&2
    exit 64
fi
if [ "$CHANNEL" = "stable" ] && [ "$PRERELEASE_PRUNE_ENABLED" -eq 1 ]; then
    echo "stable channel does not support preview-release pruning" >&2
    exit 64
fi

SOURCE_VERSION=$(awk -F'"' '/public static let short/ { print $2; exit }' \
    "${PROJECT_ROOT}/Sources/LungfishCore/AppVersion.swift")
if ! [[ "$SOURCE_VERSION" =~ ^[0-9]{4}\.([1-9]|1[0-2])\.[1-9][0-9]*$ ]]; then
    echo "invalid release version; expected YYYY.M.PATCH, found: ${SOURCE_VERSION:-<missing>}" >&2
    exit 64
fi
if [ "$PACKAGE_ONLY" -eq 0 ] && [ -z "$GITHUB_RELEASE_TAG" ] && [ -n "$SPARKLE_PUBLISH_RELEASE" ]; then
    GITHUB_RELEASE_TAG="v${SOURCE_VERSION}"
fi
if [ -n "$GITHUB_RELEASE_TAG" ] && [ "$GITHUB_RELEASE_TAG" != "v${SOURCE_VERSION}" ]; then
    echo "GitHub release tag must be v${SOURCE_VERSION}, found: $GITHUB_RELEASE_TAG" >&2
    exit 64
fi
if [ -n "$GITHUB_RELEASE_TAG" ]; then
    RELEASE_NOTES_PREFLIGHT_PATH="${SPARKLE_RELEASE_NOTES:-${PROJECT_ROOT}/docs/release-notes/${SOURCE_VERSION}.md}"
    if [ ! -f "$RELEASE_NOTES_PREFLIGHT_PATH" ]; then
        echo "detailed release notes must exist before building: $RELEASE_NOTES_PREFLIGHT_PATH" >&2
        exit 64
    fi
    case "$CHANNEL" in
        preview) expected_channel_label="Preview" ;;
        stable) expected_channel_label="Stable" ;;
        *)
            echo "invalid --channel: ${CHANNEL} (expected preview or stable)" >&2
            exit 64
            ;;
    esac
    manifest_dependency_set=$(python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["dependencySet"])' \
        "${PROJECT_ROOT}/Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json")
    if ! /usr/bin/grep -Fqx "Channel: ${expected_channel_label}" "$RELEASE_NOTES_PREFLIGHT_PATH" \
        || ! /usr/bin/grep -Eq '^Previous versioned release: v[^[:space:]]+$' "$RELEASE_NOTES_PREFLIGHT_PATH" \
        || ! /usr/bin/grep -Eq '^Stable baseline: .+' "$RELEASE_NOTES_PREFLIGHT_PATH" \
        || ! /usr/bin/grep -Fqx "Dependency set: ${manifest_dependency_set}" "$RELEASE_NOTES_PREFLIGHT_PATH" \
        || ! /usr/bin/grep -Fqx '## Dependency versions' "$RELEASE_NOTES_PREFLIGHT_PATH"; then
        echo "release notes are missing required audit field(s) for ${expected_channel_label}: $RELEASE_NOTES_PREFLIGHT_PATH" >&2
        exit 64
    fi
    if [ "$CHANNEL" = "stable" ] \
        && ! /usr/bin/grep -Fqx '## Included preview releases' "$RELEASE_NOTES_PREFLIGHT_PATH"; then
        echo "stable release notes must include: ## Included preview releases" >&2
        exit 64
    fi
fi

if [ -z "$SPARKLE_PUBLIC_ED_KEY" ] && [ -z "$RESUME_CANDIDATE" ]; then
    echo "missing Sparkle public EdDSA key; pass --sparkle-public-ed-key or set LUNGFISH_SPARKLE_PUBLIC_ED_KEY" >&2
    exit 64
fi

case "$SPARKLE_APPCAST_FILENAME" in
    ""|*/*)
        echo "invalid Sparkle appcast filename: $SPARKLE_APPCAST_FILENAME" >&2
        exit 64
        ;;
esac
case "$SPARKLE_BRIDGE_APPCAST_FILENAME" in
    */*)
        echo "invalid Sparkle bridge appcast filename: $SPARKLE_BRIDGE_APPCAST_FILENAME" >&2
        exit 64
        ;;
esac
if [ -n "$SPARKLE_BRIDGE_PUBLISH_RELEASE" ] && [ -z "$SPARKLE_BRIDGE_APPCAST_FILENAME" ]; then
    echo "Sparkle bridge appcast filename is required when a bridge release is selected" >&2
    exit 64
fi
case "$PRERELEASE_PRUNE_KEEP" in
    ''|*[!0-9]*)
        echo "invalid prerelease prune keep count: $PRERELEASE_PRUNE_KEEP" >&2
        exit 64
        ;;
esac
if [ "$PRERELEASE_PRUNE_KEEP" -lt 1 ]; then
    echo "prerelease prune keep count must be at least 1" >&2
    exit 64
fi

if [ -z "$DERIVED_DATA_PATH" ]; then
    DERIVED_DATA_PATH="${PROJECT_ROOT}/.build/release-derived-data"
fi

SPARKLE_FEED_URL=""
RELEASE_LOG_DIR="${RELEASE_DIR}/logs"
ARCHIVE_RESULT_BUNDLE_PATH="${RELEASE_LOG_DIR}/archive.xcresult"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 69
    fi
}

for command in git /usr/bin/shasum python3; do
    require_command "$command"
done
if [ ! -x "$RELEASE_DOCTOR_SCRIPT" ] || [ ! -x "$CANDIDATE_RECEIPT_SCRIPT" ] \
    || [ ! -f "$RELEASE_TARGET_SECURITY_SCRIPT" ] \
    || [ ! -f "$RELEASE_REPOSITORY_SCRIPT" ] \
    || [ ! -f "$SPARKLE_BUILD_GATE_SCRIPT" ] \
    || [ ! -f "$RELEASE_XCODE_SCRIPT" ]; then
    echo "release Doctor or candidate receipt helper is missing or not executable" >&2
    exit 69
fi

repository_args=(
    --project-root "$PROJECT_ROOT"
    --remote "$GIT_REMOTE"
)
if [ -n "$GITHUB_REPOSITORY" ]; then
    repository_args+=(--github-repository "$GITHUB_REPOSITORY")
fi
repository_output=$(python3 "$RELEASE_REPOSITORY_SCRIPT" "${repository_args[@]}")
repository_key=""
resolved_github_repository=""
while IFS='=' read -r repository_field repository_value; do
    case "$repository_field" in
        repositoryKey) repository_key="$repository_value" ;;
        githubRepository) resolved_github_repository="$repository_value" ;;
        *) echo "selected Git remote returned malformed identity" >&2; exit 64 ;;
    esac
done <<<"$repository_output"
if ! [[ "$repository_key" =~ ^[0-9a-f]{64}$ ]] \
    || ! [[ "$resolved_github_repository" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "selected Git remote returned incomplete identity" >&2
    exit 64
fi
GITHUB_REPOSITORY="$resolved_github_repository"
unset GH_HOST
export GH_REPO="github.com/${GITHUB_REPOSITORY}"
SPARKLE_FEED_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${SPARKLE_PUBLISH_RELEASE}/${SPARKLE_APPCAST_FILENAME}"

run_live_sparkle_build_gates() {
    local planned="$1"
    local feed_root="https://github.com/${GITHUB_REPOSITORY}/releases/download"
    python3 "$SPARKLE_BUILD_GATE_SCRIPT" \
        --planned "$planned" \
        --appcast-url "${feed_root}/${PREVIEW_LEGACY_SPARKLE_RELEASE}/${PREVIEW_LEGACY_APPCAST_FILENAME}"
    if [ "$CHANNEL" = stable ]; then
        python3 "$SPARKLE_BUILD_GATE_SCRIPT" \
            --planned "$planned" \
            --appcast-url "${feed_root}/${PREVIEW_SPARKLE_RELEASE}/${PREVIEW_APPCAST_FILENAME}"
        python3 "$SPARKLE_BUILD_GATE_SCRIPT" \
            --planned "$planned" \
            --appcast-url "${feed_root}/${CONTRACT_SPARKLE_PUBLISH_RELEASE}/${CONTRACT_SPARKLE_APPCAST_FILENAME}" \
            --allow-http-not-found
    else
        python3 "$SPARKLE_BUILD_GATE_SCRIPT" \
            --planned "$planned" \
            --appcast-url "${feed_root}/${CONTRACT_SPARKLE_PUBLISH_RELEASE}/${CONTRACT_SPARKLE_APPCAST_FILENAME}"
    fi
}

github_cli() {
    command gh --repo "$GH_REPO" "$@"
}

verify_versioned_release_identity() {
    if [ -z "$GITHUB_RELEASE_TAG" ] || [ "$DEFER_REMOTE_PUBLISH" -eq 1 ]; then
        return
    fi

    local head_commit
    local remote_lines
    local remote_tag_object
    local remote_tag_commit
    local direct_count
    local peeled_count
    local release_exists=0
    head_commit=$(git rev-parse HEAD)
    remote_lines=$(git ls-remote --tags "$GIT_REMOTE" \
        "refs/tags/${GITHUB_RELEASE_TAG}" \
        "refs/tags/${GITHUB_RELEASE_TAG}^{}")
    direct_count=$(printf '%s\n' "$remote_lines" \
        | awk -v ref="refs/tags/${GITHUB_RELEASE_TAG}" '$2 == ref { count += 1 } END { print count + 0 }')
    peeled_count=$(printf '%s\n' "$remote_lines" \
        | awk -v ref="refs/tags/${GITHUB_RELEASE_TAG}^{}" '$2 == ref { count += 1 } END { print count + 0 }')
    remote_tag_object=$(printf '%s\n' "$remote_lines" \
        | awk -v ref="refs/tags/${GITHUB_RELEASE_TAG}" '$2 == ref { print $1 }')
    remote_tag_commit=$(printf '%s\n' "$remote_lines" \
        | awk -v ref="refs/tags/${GITHUB_RELEASE_TAG}^{}" '$2 == ref { print $1 }')
    if [ "$direct_count" -ne 1 ] || [ "$peeled_count" -ne 1 ] \
        || [ -z "$remote_tag_object" ] || [ -z "$remote_tag_commit" ]; then
        echo "release tag must be present as one exact annotated tag: $GITHUB_RELEASE_TAG" >&2
        exit 64
    fi
    if [ "$remote_tag_commit" != "$head_commit" ]; then
        echo "release tag does not point to HEAD: $GITHUB_RELEASE_TAG ($remote_tag_commit != $head_commit)" >&2
        exit 64
    fi

    if github_cli release view "$GITHUB_RELEASE_TAG" >/dev/null 2>&1; then
        release_exists=1
    fi
    if [ "$release_exists" -eq 1 ] && [ "$RECOVER_EXISTING_RELEASE" -ne 1 ]; then
        echo "versioned GitHub release already exists; refusing to overwrite: $GITHUB_RELEASE_TAG" >&2
        exit 64
    fi
    if [ "$release_exists" -eq 0 ] && [ "$RECOVER_EXISTING_RELEASE" -eq 1 ]; then
        echo "recovery requested but versioned GitHub release does not exist: $GITHUB_RELEASE_TAG" >&2
        exit 64
    fi
    if [ "$release_exists" -eq 1 ]; then
        local release_target
        local release_is_draft
        local release_is_prerelease
        release_target=$(github_cli release view "$GITHUB_RELEASE_TAG" --json targetCommitish --jq .targetCommitish)
        if [ "$release_target" != "$head_commit" ]; then
            echo "existing GitHub release target does not match HEAD: $release_target != $head_commit" >&2
            exit 64
        fi
        release_is_prerelease=$(github_cli release view "$GITHUB_RELEASE_TAG" --json isPrerelease --jq .isPrerelease)
        if [ "$release_is_prerelease" != "$GITHUB_PRERELEASE" ]; then
            echo "existing GitHub release channel does not match --channel ${CHANNEL}: $GITHUB_RELEASE_TAG" >&2
            exit 64
        fi
        release_is_draft=$(github_cli release view "$GITHUB_RELEASE_TAG" --json isDraft --jq .isDraft)
        if [ "$release_is_draft" != "false" ]; then
            echo "recovery requires a published, non-draft release: $GITHUB_RELEASE_TAG" >&2
            exit 64
        fi
    fi
}

if [ "$PACKAGE_ONLY" -eq 0 ] && [ -n "$SPARKLE_GENERATE_APPCAST" ] && [ ! -x "$SPARKLE_GENERATE_APPCAST" ]; then
    echo "sparkle generate_appcast is not executable: $SPARKLE_GENERATE_APPCAST" >&2
    exit 69
fi

if [ "$PACKAGE_ONLY" -eq 0 ] && [ -n "$SPARKLE_ED_KEY_FILE" ] && [ ! -f "$SPARKLE_ED_KEY_FILE" ]; then
    echo "Sparkle private EdDSA key file not found: $SPARKLE_ED_KEY_FILE" >&2
    exit 69
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Lungfish.app"
RELEASE_APP_PATH="${RELEASE_DIR}/${APP_BUNDLE_FILENAME}"
APP_ICON_SOURCE="${PROJECT_ROOT}/Sources/Lungfish/AppIcon.icns"
APP_ICON_DEST="${APP_PATH}/Contents/Resources/AppIcon.icns"
METADATA_PATH="${RELEASE_DIR}/release-metadata.txt"
PACKAGE_METADATA_PATH="${RELEASE_DIR}/package-metadata.txt"
CANDIDATE_RECEIPT_PATH="${RELEASE_DIR}/unsigned-candidate-receipt.json"
APP_NOTARY_LOG="${RELEASE_DIR}/notary-app-log.json"
DMG_NOTARY_LOG="${RELEASE_DIR}/notary-dmg-log.json"

release_commit=$(git rev-parse --verify HEAD)

refresh_output_paths() {
    RELEASE_LOG_DIR="${RELEASE_DIR}/logs"
    ARCHIVE_RESULT_BUNDLE_PATH="${RELEASE_LOG_DIR}/archive.xcresult"
    RELEASE_APP_PATH="${RELEASE_DIR}/${APP_BUNDLE_FILENAME}"
    METADATA_PATH="${RELEASE_DIR}/release-metadata.txt"
    PACKAGE_METADATA_PATH="${RELEASE_DIR}/package-metadata.txt"
    CANDIDATE_RECEIPT_PATH="${RELEASE_DIR}/unsigned-candidate-receipt.json"
    APP_NOTARY_LOG="${RELEASE_DIR}/notary-app-log.json"
    DMG_NOTARY_LOG="${RELEASE_DIR}/notary-dmg-log.json"
}

if [ -n "$RESUME_CANDIDATE" ]; then
    CANDIDATE_RECEIPT_PATH=$(python3 -c \
        'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' \
        "$RESUME_CANDIDATE")
    RELEASE_DIR=$(dirname "$CANDIDATE_RECEIPT_PATH")
    refresh_output_paths
    SCRATCH_PATH=$(python3 -c \
        'import json,sys; value=json.load(open(sys.argv[1]))["build"]["scratchPath"]; assert isinstance(value,str) and value.startswith("/"); print(value)' \
        "$CANDIDATE_RECEIPT_PATH")
    APP_PATH="$RELEASE_APP_PATH"
    python3 "$RELEASE_TARGET_SECURITY_SCRIPT" validate-release-output \
        --release-dir "$RELEASE_DIR" \
        --repository-key "$repository_key"
fi

run_release_doctor() {
    local mode="$1"
    local doctor_args=(
        --mode "$mode"
        --channel "$CHANNEL"
        --remote "$GIT_REMOTE"
        --github-repository "$GITHUB_REPOSITORY"
    )
    if [ "$mode" = package ]; then
        doctor_args+=(
            --scratch-path "$SCRATCH_PATH"
            --release-dir "$RELEASE_DIR"
            --archive-path "$ARCHIVE_PATH"
            --derived-data-path "$DERIVED_DATA_PATH"
        )
    fi
    if [ "$mode" = credentials ]; then
        doctor_args+=(
            --signing-identity "$SIGNING_IDENTITY"
            --team-id "$TEAM_ID"
            --notary-profile "$NOTARY_PROFILE"
        )
        if [ -n "$SPARKLE_ED_KEY_FILE" ]; then
            doctor_args+=(--sparkle-ed-key-file "$SPARKLE_ED_KEY_FILE")
        fi
    fi
    "$RELEASE_DOCTOR_SCRIPT" "${doctor_args[@]}"
}

relative_to_project_root() {
    case "$1" in
        "$PROJECT_ROOT"/*)
            printf '%s\n' "${1#"$PROJECT_ROOT"/}"
            ;;
        "$PROJECT_ROOT")
            printf '.\n'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

install_app_icon() {
    if [ ! -f "$APP_ICON_SOURCE" ]; then
        echo "app icon source not found: $APP_ICON_SOURCE" >&2
        exit 72
    fi

    /usr/bin/install -d "$(dirname "$APP_ICON_DEST")"
    /usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST"

    local info_plist="${APP_PATH}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$info_plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$info_plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$info_plist"
}

configure_sparkle_info_plist() {
    local info_plist="$1"
    if [ ! -f "$info_plist" ]; then
        echo "Info.plist not found: $info_plist" >&2
        exit 72
    fi

    /usr/bin/plutil -replace CFBundleVersion -string "$SPARKLE_BUILD_NUMBER" "$info_plist"
    /usr/bin/plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL" "$info_plist"
    /usr/bin/plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$info_plist"
    /usr/bin/plutil -replace SUVerifyUpdateBeforeExtraction -bool YES "$info_plist"
    /usr/bin/plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$info_plist"
    /usr/bin/plutil -replace CFBundleName -string "$APP_SHORT_NAME" "$info_plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_IDENTIFIER" "$info_plist"
    /usr/bin/plutil -replace LungfishReleaseChannel -string "$RELEASE_CHANNEL" "$info_plist"

    local actual_feed
    local actual_public_key
    local actual_display_name
    local actual_short_name
    local actual_bundle_identifier
    local actual_channel
    actual_feed=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$info_plist")
    actual_public_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$info_plist")
    actual_display_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$info_plist")
    actual_short_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$info_plist")
    actual_bundle_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")
    actual_channel=$(/usr/libexec/PlistBuddy -c "Print :LungfishReleaseChannel" "$info_plist")
    if [ "$actual_feed" != "$SPARKLE_FEED_URL" ] \
        || [ "$actual_public_key" != "$SPARKLE_PUBLIC_ED_KEY" ] \
        || [ "$actual_display_name" != "$APP_DISPLAY_NAME" ] \
        || [ "$actual_short_name" != "$APP_SHORT_NAME" ] \
        || [ "$actual_bundle_identifier" != "$APP_BUNDLE_IDENTIFIER" ] \
        || [ "$actual_channel" != "$RELEASE_CHANNEL" ]; then
        echo "failed to configure Sparkle or bundle identity Info.plist keys" >&2
        exit 72
    fi
}

sparkle_release_notes_source() {
    if [ -n "$SPARKLE_RELEASE_NOTES" ]; then
        printf '%s\n' "$SPARKLE_RELEASE_NOTES"
    else
        printf '%s\n' "${PROJECT_ROOT}/docs/release-notes/${VERSION}.md"
    fi
}

publish_github_release_dmg() {
    if [ -z "$GITHUB_RELEASE_TAG" ]; then
        return
    fi
    if [ "$DEFER_REMOTE_PUBLISH" -eq 1 ]; then
        return
    fi

    # Signing and notarization can take hours, so repeat the identity and
    # collision/recovery checks immediately before changing GitHub.
    verify_versioned_release_identity

    local notes_source
    local target_commit
    notes_source="$(sparkle_release_notes_source)"
    target_commit="$(git rev-parse HEAD)"

    if github_cli release view "$GITHUB_RELEASE_TAG" >/dev/null 2>&1; then
        local existing_digest
        local local_digest
        existing_digest=$(github_cli release view "$GITHUB_RELEASE_TAG" --json assets \
            --jq ".assets[] | select(.name == \"$(basename "$DMG_PATH")\") | .digest")
        if [ -n "$existing_digest" ]; then
            local_digest="sha256:$(/usr/bin/shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
            if [ "$existing_digest" != "$local_digest" ]; then
                echo "existing release DMG digest differs; refusing recovery overwrite: $GITHUB_RELEASE_TAG" >&2
                exit 64
            fi
            printf 'Existing release DMG already matches local artifact; keeping it: %s\n' "$DMG_PATH"
            return
        fi
        github_cli release upload "$GITHUB_RELEASE_TAG" "$DMG_PATH"
        return
    fi

    local create_args=(
        release create "$GITHUB_RELEASE_TAG"
        "$DMG_PATH"
        --title "$GITHUB_RELEASE_TAG"
        --target "$target_commit"
    )
    if [ "$GITHUB_PRERELEASE" = "true" ]; then
        create_args+=(--prerelease)
    else
        # A full release fires the 'released' event, which runs CI's heavy
        # board (build smoke + toolset conformance) on this tag.
        create_args+=(--latest)
    fi
    create_args+=(--notes-file "$notes_source")
    github_cli "${create_args[@]}"
}

ensure_mutable_release() {
    local release_tag="$1"
    local title="$2"
    local notes="$3"
    local target_commit
    target_commit="$(git rev-parse HEAD)"
    if ! github_cli release view "$release_tag" >/dev/null 2>&1; then
        github_cli release create "$release_tag" \
            --title "$title" \
            --notes "$notes" \
            --prerelease \
            --target "$target_commit"
        return
    fi
    local actual_target
    local actual_draft
    local actual_prerelease
    actual_target=$(github_cli release view "$release_tag" --json targetCommitish --jq .targetCommitish)
    actual_draft=$(github_cli release view "$release_tag" --json isDraft --jq .isDraft)
    actual_prerelease=$(github_cli release view "$release_tag" --json isPrerelease --jq .isPrerelease)
    if [ "$actual_draft" != false ] || [ "$actual_prerelease" != true ]; then
        echo "mutable Sparkle release has unsafe draft/channel state: $release_tag" >&2
        exit 64
    fi
    if [ "$actual_target" != "$target_commit" ]; then
        github_cli release edit "$release_tag" --target "$target_commit"
    fi
}

publish_mutable_asset_if_changed() {
    local release_tag="$1"
    local local_path="$2"
    local asset_name
    local expected_digest
    local expected_size
    local remote_record
    asset_name=$(basename "$local_path")
    expected_digest="sha256:$(/usr/bin/shasum -a 256 "$local_path" | awk '{print $1}')"
    expected_size=$(/usr/bin/stat -f %z "$local_path")
    remote_record=$(github_cli release view "$release_tag" --json assets \
        --jq ".assets[] | select(.name == \"${asset_name}\") | [.digest,.size] | @tsv")
    if [ "$remote_record" = "${expected_digest}"$'\t'"${expected_size}" ]; then
        return
    fi
    github_cli release upload "$release_tag" "$local_path" --clobber
}

generate_sparkle_appcast() {
    if [ -z "$SPARKLE_GENERATE_APPCAST" ]; then
        return
    fi

    if [ -z "$SPARKLE_APPCAST_DIR" ]; then
        SPARKLE_APPCAST_DIR="${RELEASE_DIR}/sparkle-appcast"
    fi

    local dmg_name="Lungfish-${VERSION}-arm64.dmg"
    local appcast_dmg="${SPARKLE_APPCAST_DIR}/${dmg_name}"
    local notes_source
    local notes_dest="${SPARKLE_APPCAST_DIR}/Lungfish-${VERSION}-arm64.md"
    local download_url_prefix="$SPARKLE_DOWNLOAD_URL_PREFIX"
    local release_notes_url_prefix

    notes_source="$(sparkle_release_notes_source)"
    if [ -z "$download_url_prefix" ]; then
        download_url_prefix="https://github.com/${GITHUB_REPOSITORY}/releases/download/${GITHUB_RELEASE_TAG:-v${VERSION}}"
    fi
    case "$download_url_prefix" in
        */) ;;
        *) download_url_prefix="${download_url_prefix}/" ;;
    esac
    release_notes_url_prefix="$download_url_prefix"
    if [ -n "$SPARKLE_PUBLISH_RELEASE" ]; then
        release_notes_url_prefix="https://github.com/${GITHUB_REPOSITORY}/releases/download/${SPARKLE_PUBLISH_RELEASE}/"
    fi

    mkdir -p "$SPARKLE_APPCAST_DIR"
    /bin/cp -p "$DMG_PATH" "$appcast_dmg"

    if [ -f "$notes_source" ]; then
        /usr/bin/install -m 644 "$notes_source" "$notes_dest"
    fi

    SPARKLE_APPCAST_PATH="${SPARKLE_APPCAST_DIR}/${SPARKLE_APPCAST_FILENAME}"
    local appcast_args=(
        --download-url-prefix "$download_url_prefix"
        --release-notes-url-prefix "$release_notes_url_prefix"
        -o "$SPARKLE_APPCAST_PATH"
    )
    if [ -n "$SPARKLE_ED_KEY_FILE" ]; then
        appcast_args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
    fi

    "$SPARKLE_GENERATE_APPCAST" "${appcast_args[@]}" "$SPARKLE_APPCAST_DIR"

    if [ ! -f "$SPARKLE_APPCAST_PATH" ]; then
        echo "Sparkle appcast was not generated at expected path: $SPARKLE_APPCAST_PATH" >&2
        exit 72
    fi

    if [ -n "$SPARKLE_PUBLISH_RELEASE" ] && [ "$DEFER_REMOTE_PUBLISH" -eq 0 ]; then
        local feed_title="Lungfish Sparkle Preview Appcast"
        local feed_notes="Mutable Sparkle preview appcast feed for Lungfish Genome Explorer."
        if [ "$CHANNEL" = "stable" ]; then
            feed_title="Lungfish Sparkle Stable Appcast"
            feed_notes="Mutable Sparkle stable appcast feed for Lungfish Genome Explorer."
        fi
        ensure_mutable_release "$SPARKLE_PUBLISH_RELEASE" "$feed_title" "$feed_notes"
        publish_mutable_asset_if_changed "$SPARKLE_PUBLISH_RELEASE" "$SPARKLE_APPCAST_PATH"
        if [ -f "$notes_dest" ]; then
            publish_mutable_asset_if_changed "$SPARKLE_PUBLISH_RELEASE" "$notes_dest"
        fi
        for signed_feed_asset in "$SPARKLE_APPCAST_PATH".* "$notes_dest".*; do
            if [ -f "$signed_feed_asset" ]; then
                publish_mutable_asset_if_changed "$SPARKLE_PUBLISH_RELEASE" "$signed_feed_asset"
            fi
        done
    fi

    if [ -n "$SPARKLE_BRIDGE_PUBLISH_RELEASE" ] && [ "$DEFER_REMOTE_PUBLISH" -eq 0 ]; then
        local bridge_appcast_path="${SPARKLE_APPCAST_DIR}/${SPARKLE_BRIDGE_APPCAST_FILENAME}"
        /bin/cp -p "$SPARKLE_APPCAST_PATH" "$bridge_appcast_path"

        ensure_mutable_release \
            "$SPARKLE_BRIDGE_PUBLISH_RELEASE" \
            "Lungfish Sparkle Legacy Bridge Appcast" \
            "Mutable Sparkle appcast bridge for legacy Lungfish prerelease channels."
        publish_mutable_asset_if_changed "$SPARKLE_BRIDGE_PUBLISH_RELEASE" "$bridge_appcast_path"
    fi
}

prune_github_prereleases() {
    if [ "$PRERELEASE_PRUNE_ENABLED" -eq 0 ] || [ "$DEFER_REMOTE_PUBLISH" -eq 1 ]; then
        return
    fi
    if [ -z "$GITHUB_RELEASE_TAG" ]; then
        echo "--prune-prereleases requires a GitHub release tag" >&2
        exit 64
    fi
    PRERELEASE_PRUNE_REPORT_PATH="${RELEASE_DIR}/prerelease-prune-plan.json"
    python3 "$PRERELEASE_PRUNE_SCRIPT" \
        --current-tag "$GITHUB_RELEASE_TAG" \
        --keep "$PRERELEASE_PRUNE_KEEP" \
        --sparkle-release "$SPARKLE_PUBLISH_RELEASE" \
        --notes-root "${PROJECT_ROOT}/docs/release-notes" \
        --report-path "$PRERELEASE_PRUNE_REPORT_PATH" \
        --apply
}

prepare_release_dir() {
    /bin/rm -rf "$RELEASE_DIR"
    /bin/mkdir -p "$RELEASE_DIR"
    case "$ARCHIVE_PATH" in
        "$RELEASE_DIR"/*) ;;
        *) /bin/rm -rf "$ARCHIVE_PATH" ;;
    esac
}

resolved_build_timestamp() {
    if [ -n "${LUNGFISH_BUILD_TIMESTAMP:-}" ]; then
        /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LUNGFISH_BUILD_TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null
        printf '%s\n' "$LUNGFISH_BUILD_TIMESTAMP"
        return
    fi

    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        /bin/date -u -r "$SOURCE_DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ"
        return
    fi

    /bin/date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [ -z "$RESUME_CANDIDATE" ]; then
    if [ -z "$SCRATCH_PATH" ]; then
        SCRATCH_PATH="${LUNGFISH_RELEASE_SCRATCH_ROOT:-/private/var/tmp/lungfish-release-swiftpm}/${repository_key}/${release_commit}"
    fi
    case "$SCRATCH_PATH" in
        /*) ;;
        *) echo "release scratch path must be absolute" >&2; exit 64 ;;
    esac

    # The coordinator owns the first request-level Doctor gate. The builder
    # repeats Doctor immediately before its own destructive output boundary so
    # direct builder callers cannot bypass the same safety contract.
    if [ "$PACKAGE_ONLY" -eq 0 ]; then
        run_release_doctor credentials
    fi
    run_release_doctor package

    for command in rg xcodebuild /usr/bin/xcrun /usr/bin/ditto /usr/bin/mktemp /usr/bin/plutil /usr/libexec/PlistBuddy; do
        require_command "$command"
    done

    umask 077
    prepare_release_dir
    /bin/mkdir -p "$RELEASE_LOG_DIR" "$DERIVED_DATA_PATH"
    python3 "$RELEASE_TARGET_SECURITY_SCRIPT" record-release-output \
        --release-dir "$RELEASE_DIR" \
        --repository-key "$repository_key"
    : >"${DERIVED_DATA_PATH}/.lungfish-derived-data-output"
    /bin/rm -rf "$ARCHIVE_RESULT_BUNDLE_PATH"
    /bin/mkdir -p "$SCRATCH_PATH"
    cd "$PROJECT_ROOT"

    if [ -n "${SOURCE_DATE_EPOCH:-}" ] && [ -z "${LUNGFISH_BUILD_TIMESTAMP:-}" ]; then
        LUNGFISH_BUILD_TIMESTAMP="$(resolved_build_timestamp)"
        export LUNGFISH_BUILD_TIMESTAMP
    fi

    if [ -z "$SPARKLE_BUILD_NUMBER" ]; then
        SPARKLE_BUILD_NUMBER=$(git rev-list --count HEAD)
    fi
    SWIFT_BUILD_PREFIX_MAP_ARGS=(
        -Xswiftc -debug-prefix-map
        -Xswiftc "$SCRATCH_PATH=/swiftpm-build"
        -Xswiftc -debug-prefix-map
        -Xswiftc "$PROJECT_ROOT=/workspace"
        -Xswiftc -file-compilation-dir
        -Xswiftc /workspace
        -Xcc "-ffile-prefix-map=$SCRATCH_PATH=/swiftpm-build"
        -Xcc "-fdebug-prefix-map=$SCRATCH_PATH=/swiftpm-build"
        -Xcc "-ffile-prefix-map=$PROJECT_ROOT=/workspace"
        -Xcc "-fdebug-prefix-map=$PROJECT_ROOT=/workspace"
        -Xlinker -oso_prefix
        -Xlinker "$SCRATCH_PATH/"
    )

    # Xcode canonicalizes /private/var and /private/tmp through their shorter
    # aliases in compiler inputs. Map both spellings so a caller-selected
    # DerivedData directory cannot leak into the unsigned candidate.
    XCODE_DERIVED_DATA_ALIAS="$DERIVED_DATA_PATH"
    case "$DERIVED_DATA_PATH" in
        /private/var/*|/private/tmp/*)
            XCODE_DERIVED_DATA_ALIAS="${DERIVED_DATA_PATH#/private}"
            ;;
        /var/*|/tmp/*)
            XCODE_DERIVED_DATA_ALIAS="/private${DERIVED_DATA_PATH}"
            ;;
    esac

    XCODE_OTHER_SWIFT_FLAGS="-debug-prefix-map $SCRATCH_PATH=/swiftpm-build -debug-prefix-map $PROJECT_ROOT=/workspace -debug-prefix-map $DERIVED_DATA_PATH=/xcode-derived -file-compilation-dir /workspace"
    XCODE_OTHER_CFLAGS="-ffile-prefix-map=$SCRATCH_PATH=/swiftpm-build -fdebug-prefix-map=$SCRATCH_PATH=/swiftpm-build -ffile-prefix-map=$PROJECT_ROOT=/workspace -fdebug-prefix-map=$PROJECT_ROOT=/workspace -ffile-prefix-map=$DERIVED_DATA_PATH=/xcode-derived -fdebug-prefix-map=$DERIVED_DATA_PATH=/xcode-derived"
    if [ "$XCODE_DERIVED_DATA_ALIAS" != "$DERIVED_DATA_PATH" ]; then
        XCODE_OTHER_SWIFT_FLAGS="$XCODE_OTHER_SWIFT_FLAGS -debug-prefix-map $XCODE_DERIVED_DATA_ALIAS=/xcode-derived"
        XCODE_OTHER_CFLAGS="$XCODE_OTHER_CFLAGS -ffile-prefix-map=$XCODE_DERIVED_DATA_ALIAS=/xcode-derived -fdebug-prefix-map=$XCODE_DERIVED_DATA_ALIAS=/xcode-derived"
    fi

    # Release transactions are fail-only. Repair is a separate development action.
    /bin/bash "$PROJECT_ROOT/scripts/check-package-resolved-consistency.sh" "$PROJECT_ROOT"

    LUNGFISH_SKIP_EMBED_LUNGFISH_CLI=1 \
    LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS=1 \
    xcodebuild -project Lungfish.xcodeproj \
        -scheme Lungfish \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -archivePath "$ARCHIVE_PATH" \
        ARCHS=arm64 \
        EXCLUDED_ARCHS=x86_64 \
        ONLY_ACTIVE_ARCH=YES \
        OTHER_SWIFT_FLAGS="\$(inherited) $XCODE_OTHER_SWIFT_FLAGS" \
        OTHER_CFLAGS="\$(inherited) $XCODE_OTHER_CFLAGS" \
        OTHER_CPLUSPLUSFLAGS="\$(inherited) $XCODE_OTHER_CFLAGS" \
        CURRENT_PROJECT_VERSION="$SPARKLE_BUILD_NUMBER" \
        LUNGFISH_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        -disableAutomaticPackageResolution \
        -showBuildTimingSummary \
        -resultBundlePath "$ARCHIVE_RESULT_BUNDLE_PATH" \
        archive

    if [ ! -d "$APP_PATH" ]; then
        echo "archived app not found: $APP_PATH" >&2
        exit 72
    fi
    python3 "$RELEASE_TARGET_SECURITY_SCRIPT" record-archive \
        --archive-path "$ARCHIVE_PATH" \
        --repository-key "$repository_key"

    /usr/bin/xcrun swift build \
        --package-path "$PROJECT_ROOT" \
        --product lungfish-cli \
        --configuration release \
        --arch arm64 \
        --scratch-path "$SCRATCH_PATH" \
        "${SWIFT_BUILD_PREFIX_MAP_ARGS[@]}"

    CLI_SOURCE="${SCRATCH_PATH}/arm64-apple-macosx/release/lungfish-cli"
    CLI_DEST="${APP_PATH}/Contents/MacOS/lungfish-cli"
    WORKFLOW_TOOLS_DIR="${APP_PATH}/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"

    if [ ! -f "$CLI_SOURCE" ]; then
        echo "built CLI not found: $CLI_SOURCE" >&2
        exit 72
    fi

    /usr/bin/install -m 755 "$CLI_SOURCE" "$CLI_DEST"
    /bin/bash scripts/sanitize-bundled-tools.sh \
        --adhoc-seal \
        "$APP_PATH/Contents/MacOS" \
        "$WORKFLOW_TOOLS_DIR"
    install_app_icon
    configure_sparkle_info_plist "$APP_PATH/Contents/Info.plist"

    scripts/smoke-test-release-tools.sh "$APP_PATH" \
        --portability-only \
        --allowed-swiftpm-fallback "$SCRATCH_PATH"

    /usr/bin/ditto "$APP_PATH" "$RELEASE_APP_PATH"
    scripts/smoke-test-release-tools.sh "$RELEASE_APP_PATH" \
        --allowed-swiftpm-fallback "$SCRATCH_PATH"

    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${RELEASE_APP_PATH}/Contents/Info.plist")
    if [ "$VERSION" != "$SOURCE_VERSION" ]; then
        echo "packaged app version does not match source version: $VERSION != $SOURCE_VERSION" >&2
        exit 65
    fi

    "$CANDIDATE_RECEIPT_SCRIPT" create \
        --app "$RELEASE_APP_PATH" \
        --output "$CANDIDATE_RECEIPT_PATH" \
        --channel "$CHANNEL" \
        --scratch-path "$SCRATCH_PATH"

    COMMIT_SHA=$(git rev-parse HEAD)
    cat >"$PACKAGE_METADATA_PATH" <<EOF
version=${VERSION}
build_number=${SPARKLE_BUILD_NUMBER}
channel=${CHANNEL}
git_commit=${COMMIT_SHA}
scratch_path=${SCRATCH_PATH}
candidate_app=${RELEASE_APP_PATH}
candidate_receipt=${CANDIDATE_RECEIPT_PATH}
archive_path=${ARCHIVE_PATH}
EOF

    if [ "$PACKAGE_ONLY" -eq 1 ]; then
        printf 'Unsigned package complete:\n'
        printf '  App: %s\n' "$RELEASE_APP_PATH"
        printf '  Receipt: %s\n' "$CANDIDATE_RECEIPT_PATH"
        printf '  Metadata: %s\n' "$PACKAGE_METADATA_PATH"
        exit 0
    fi

    APP_PATH="$RELEASE_APP_PATH"
fi

# Recheck credentials after packaging and immediately before receipt verification
# and the first Developer ID codesign call. A default credentialed build also ran
# this Doctor before compilation; resume runs have no compilation to guard.
run_release_doctor credentials
"$CANDIDATE_RECEIPT_SCRIPT" verify \
    --app "$APP_PATH" \
    --receipt "$CANDIDATE_RECEIPT_PATH" \
    --channel "$CHANNEL" \
    --scratch-path "$SCRATCH_PATH"
VERIFIED_SPARKLE_BUILD_NUMBER=$(python3 -c \
    'import json,sys; value=json.load(open(sys.argv[1]))["release"]["build"]; assert isinstance(value,str) and value.isdigit() and int(value) > 0; print(value)' \
    "$CANDIDATE_RECEIPT_PATH")
python3 "$RELEASE_TARGET_SECURITY_SCRIPT" validate-release-output \
    --release-dir "$RELEASE_DIR" \
    --repository-key "$repository_key"

APP_NOTARY_ZIP="${RELEASE_DIR}/Lungfish-app-notary.zip"
SIGNED_APP_PATH="${RELEASE_DIR}/signed/${APP_BUNDLE_FILENAME}"
DMG_PATH="${RELEASE_DIR}/Lungfish-${SOURCE_VERSION}-arm64.dmg"

validate_signed_output_target() {
    python3 "$RELEASE_TARGET_SECURITY_SCRIPT" validate-signed-output \
        --release-dir "$RELEASE_DIR" \
        --signed-app-path "$SIGNED_APP_PATH" \
        --repository-key "$repository_key"
}

prepare_signed_output_parent() {
    validate_signed_output_target
    if [ ! -d "$(dirname "$SIGNED_APP_PATH")" ]; then
        /bin/mkdir "$(dirname "$SIGNED_APP_PATH")"
        /bin/chmod 700 "$(dirname "$SIGNED_APP_PATH")"
    fi
    validate_signed_output_target
}

validate_signed_output_target

# A verified receipt makes these exact paths safe retry derivatives. Remove
# only bounded signing/notary outputs; never remove the unsigned app, receipt,
# package metadata, archive, DerivedData, or deterministic scratch.
clear_verified_retry_artifacts() {
    local retry_path
    local signed_parent
    for retry_path in \
        "$APP_NOTARY_ZIP" \
        "$APP_NOTARY_LOG" \
        "$DMG_NOTARY_LOG" \
        "$DMG_PATH" \
        "$METADATA_PATH"
    do
        case "$retry_path" in
            "$RELEASE_DIR"/*) /bin/rm -f "$retry_path" ;;
            *) echo "refusing retry cleanup outside receipt directory" >&2; exit 64 ;;
        esac
    done
    case "$SIGNED_APP_PATH" in
        "$RELEASE_DIR"/*)
            signed_parent=$(dirname "$SIGNED_APP_PATH")
            if [ -L "$signed_parent" ]; then
                echo "refusing signed-app cleanup through a symlink" >&2
                exit 64
            fi
            /bin/rm -rf "$SIGNED_APP_PATH"
            /bin/rmdir "$signed_parent" 2>/dev/null || true
            ;;
        *) echo "refusing signed-app cleanup outside receipt directory" >&2; exit 64 ;;
    esac
}

cleanup_release_workdirs() {
    if [ "${RECOVERY_MOUNTED:-0}" -eq 1 ] && [ -n "${RECOVERY_MOUNT_POINT:-}" ]; then
        echo "recovery mount remains attached; preserving private recovery workspace" >&2
    fi
    if [ -n "${SIGNING_WORK_DIR:-}" ]; then
        /bin/rm -rf "$SIGNING_WORK_DIR"
    fi
    if [ -n "${DMG_STAGING_DIR:-}" ]; then
        /bin/rm -rf "$DMG_STAGING_DIR"
    fi
    if [ "${RECOVERY_MOUNTED:-0}" -eq 0 ] && [ -n "${RECOVERY_WORK_DIR:-}" ]; then
        /bin/rm -rf "$RECOVERY_WORK_DIR"
    fi
}
trap cleanup_release_workdirs EXIT

remote_asset_record() {
    local release_tag="$1"
    local asset_name="$2"
    local record
    local line_count
    record=$(github_cli release view "$release_tag" --json assets \
        --jq ".assets[] | select(.name == \"${asset_name}\") | [.digest,.size] | @tsv")
    line_count=$(printf '%s\n' "$record" | awk 'NF { count += 1 } END { print count + 0 }')
    if [ "$line_count" -ne 1 ]; then
        echo "immutable release asset is missing or ambiguous: ${asset_name}" >&2
        exit 64
    fi
    printf '%s\n' "$record"
}

verify_file_matches_remote_asset() {
    local path="$1"
    local expected_digest="$2"
    local expected_size="$3"
    local label="$4"
    local actual_digest
    local actual_size
    if [ ! -f "$path" ] || [ -L "$path" ]; then
        echo "$label must be a regular non-symlink file: $path" >&2
        exit 64
    fi
    case "$expected_digest" in
        sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) echo "$label remote digest is missing or malformed" >&2; exit 64 ;;
    esac
    if [ "${#expected_digest}" -ne 71 ] || ! [[ "$expected_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "$label remote digest or size is malformed" >&2
        exit 64
    fi
    actual_digest="sha256:$(/usr/bin/shasum -a 256 "$path" | awk '{print $1}')"
    actual_size=$(/usr/bin/stat -f %z "$path")
    if [ "$actual_digest" != "$expected_digest" ] || [ "$actual_size" != "$expected_size" ]; then
        echo "$label does not match the immutable GitHub release asset" >&2
        exit 64
    fi
}

verify_recovered_signed_app() {
    local app="$1"
    if [ ! -d "$app" ] || [ -L "$app" ]; then
        echo "recovered signed app is unavailable or unsafe: $app" >&2
        exit 64
    fi
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
    /usr/bin/xcrun stapler validate "$app"
    scripts/smoke-test-release-tools.sh "$app" \
        --allowed-swiftpm-fallback "$SCRATCH_PATH"
}

recover_immutable_release_artifacts() {
    local asset_record
    local remote_digest
    local remote_size
    local downloaded_dmg
    asset_record=$(remote_asset_record "$GITHUB_RELEASE_TAG" "$(basename "$DMG_PATH")")
    IFS=$'\t' read -r remote_digest remote_size <<<"$asset_record"

    if [ -e "$DMG_PATH" ] || [ -L "$DMG_PATH" ]; then
        verify_file_matches_remote_asset "$DMG_PATH" "$remote_digest" "$remote_size" \
            "local recovery DMG"
    else
        RECOVERY_WORK_DIR=$(/usr/bin/mktemp -d "${RELEASE_DIR}/.immutable-recovery.XXXXXX")
        /bin/chmod 700 "$RECOVERY_WORK_DIR"
        github_cli release download "$GITHUB_RELEASE_TAG" \
            --pattern "$(basename "$DMG_PATH")" \
            --dir "$RECOVERY_WORK_DIR"
        downloaded_dmg="${RECOVERY_WORK_DIR}/$(basename "$DMG_PATH")"
        verify_file_matches_remote_asset "$downloaded_dmg" "$remote_digest" "$remote_size" \
            "downloaded recovery DMG"
        /bin/mv "$downloaded_dmg" "$DMG_PATH"
    fi

    if [ -e "$SIGNED_APP_PATH" ] || [ -L "$SIGNED_APP_PATH" ]; then
        verify_recovered_signed_app "$SIGNED_APP_PATH"
        return
    fi

    if [ -z "${RECOVERY_WORK_DIR:-}" ]; then
        RECOVERY_WORK_DIR=$(/usr/bin/mktemp -d "${RELEASE_DIR}/.immutable-recovery.XXXXXX")
        /bin/chmod 700 "$RECOVERY_WORK_DIR"
    fi
    RECOVERY_MOUNT_POINT="${RECOVERY_WORK_DIR}/mount"
    local extracted_app="${RECOVERY_WORK_DIR}/${APP_BUNDLE_FILENAME}"
    /bin/mkdir -p "$RECOVERY_MOUNT_POINT"
    /usr/bin/hdiutil attach \
        -readonly \
        -nobrowse \
        -mountpoint "$RECOVERY_MOUNT_POINT" \
        "$DMG_PATH" >/dev/null
    RECOVERY_MOUNTED=1
    if [ ! -d "${RECOVERY_MOUNT_POINT}/${APP_BUNDLE_FILENAME}" ] \
        || [ -L "${RECOVERY_MOUNT_POINT}/${APP_BUNDLE_FILENAME}" ]; then
        echo "immutable DMG does not contain the expected app bundle" >&2
        exit 64
    fi
    /usr/bin/ditto "${RECOVERY_MOUNT_POINT}/${APP_BUNDLE_FILENAME}" "$extracted_app"
    if ! /usr/bin/hdiutil detach "$RECOVERY_MOUNT_POINT" >/dev/null; then
        echo "recovery DMG detach failed; private recovery workspace retained" >&2
        exit 81
    fi
    RECOVERY_MOUNTED=0
    verify_recovered_signed_app "$extracted_app"
    prepare_signed_output_parent
    /bin/mv "$extracted_app" "$SIGNED_APP_PATH"
}

verify_versioned_release_identity

for command in /usr/bin/codesign /usr/bin/hdiutil /usr/bin/ditto /usr/bin/mktemp /usr/bin/xcrun /usr/bin/file /usr/bin/find /usr/bin/stat; do
    require_command "$command"
done
if [ "$DEFER_REMOTE_PUBLISH" -eq 0 ] && { [ -n "$SPARKLE_PUBLISH_RELEASE" ] || [ -n "$SPARKLE_BRIDGE_PUBLISH_RELEASE" ] || [ -n "$GITHUB_RELEASE_TAG" ]; }; then
    require_command gh
fi

if [ "$RECOVER_EXISTING_RELEASE" -eq 1 ]; then
    # Once the immutable release exists, its exact DMG is the source of truth.
    # Recovery must never rebuild, re-sign, re-notarize, replace, or upload it.
    recover_immutable_release_artifacts
    APP_PATH="$SIGNED_APP_PATH"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
else
    clear_verified_retry_artifacts
    SIGNING_WORK_DIR=$(/usr/bin/mktemp -d "${RELEASE_DIR}/.signing-work.XXXXXX")
    /bin/chmod 700 "$SIGNING_WORK_DIR"
    APP_PATH="${SIGNING_WORK_DIR}/${APP_BUNDLE_FILENAME}"
    /usr/bin/ditto "$RELEASE_APP_PATH" "$APP_PATH"

CLI_DEST="${APP_PATH}/Contents/MacOS/lungfish-cli"
WORKFLOW_TOOLS_DIR="${APP_PATH}/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools"

sign_developer_id_runtime() {
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --generate-entitlement-der \
        "$1"
}

sign_sparkle_framework() {
    local sparkle_framework="$1"
    if [ ! -d "$sparkle_framework" ]; then
        return
    fi

    local sparkle_version_dir="${sparkle_framework}/Versions/B"
    local nested_bundle
    for nested_bundle in \
        "${sparkle_version_dir}/Updater.app" \
        "${sparkle_version_dir}/XPCServices/Downloader.xpc" \
        "${sparkle_version_dir}/XPCServices/Installer.xpc"
    do
        if [ -d "$nested_bundle" ]; then
            sign_developer_id_runtime "$nested_bundle"
        fi
    done

    local nested_macho
    for nested_macho in \
        "${sparkle_version_dir}/Autoupdate" \
        "${sparkle_version_dir}/Sparkle"
    do
        if [ -f "$nested_macho" ]; then
            sign_developer_id_runtime "$nested_macho"
        fi
    done

    sign_developer_id_runtime "$sparkle_framework"
}

run_live_sparkle_build_gates "$VERIFIED_SPARKLE_BUILD_NUMBER"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements" \
    --generate-entitlement-der \
    "$CLI_DEST"

# Sign every Mach-O file bundled under Resources/Tools individually.
# `codesign --deep` is deprecated and does not recurse into resource bundles,
# so notarization fails unless the bootstrap binary is signed inside-out.
if [ -d "$WORKFLOW_TOOLS_DIR" ]; then
    while IFS= read -r -d '' candidate; do
        if /usr/bin/file -b "$candidate" | grep -q '^Mach-O'; then
            /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                --options runtime \
                --timestamp \
                --generate-entitlement-der \
                "$candidate"
        fi
    done < <(/usr/bin/find "$WORKFLOW_TOOLS_DIR" -type f -print0)
fi

# Sparkle ships nested helper tools inside its framework. Xcode's archive may
# leave those helpers with development or ad-hoc signatures, which notarization
# rejects even when the outer app is re-signed for Developer ID.
sign_sparkle_framework "$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Outer app signing seals the bundle. Every nested Mach-O was signed above,
# so we deliberately omit `--deep` (which can strip or overwrite those inner
# signatures in unpredictable ways on recent macOS releases).
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements" \
    --generate-entitlement-der \
    "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
scripts/smoke-test-release-tools.sh "$APP_PATH" \
    --allowed-swiftpm-fallback "$SCRATCH_PATH"

/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"

/usr/bin/xcrun notarytool submit "$APP_NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$APP_NOTARY_LOG"

/bin/rm -f "$APP_NOTARY_ZIP"

/usr/bin/xcrun stapler staple "$APP_PATH"

/bin/rm -rf "$SIGNED_APP_PATH"
prepare_signed_output_parent
/usr/bin/ditto "$APP_PATH" "$SIGNED_APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
if [ "$VERSION" != "$SOURCE_VERSION" ]; then
    echo "archived app version does not match source version: $VERSION != $SOURCE_VERSION" >&2
    exit 65
fi
if [ "$DMG_PATH" != "${RELEASE_DIR}/Lungfish-${VERSION}-arm64.dmg" ]; then
    echo "retry DMG path version does not match signed app version" >&2
    exit 65
fi
DMG_STAGING_DIR=$(/usr/bin/mktemp -d "${RELEASE_DIR}/.dmg-staging.XXXXXX")

/usr/bin/ditto "$APP_PATH" "${DMG_STAGING_DIR}/${APP_BUNDLE_FILENAME}"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

/usr/bin/hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -format UDZO \
    "$DMG_PATH"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --timestamp \
    --generate-entitlement-der \
    "$DMG_PATH"

/usr/bin/xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$DMG_NOTARY_LOG"

/usr/bin/xcrun stapler staple "$DMG_PATH"

run_live_sparkle_build_gates "$VERIFIED_SPARKLE_BUILD_NUMBER"
publish_github_release_dmg
fi

if [ "$VERSION" != "$SOURCE_VERSION" ]; then
    echo "release artifact version does not match source version: $VERSION != $SOURCE_VERSION" >&2
    exit 65
fi
run_live_sparkle_build_gates "$VERIFIED_SPARKLE_BUILD_NUMBER"
generate_sparkle_appcast
prune_github_prereleases

DMG_SHA=$(/usr/bin/shasum -a 256 "$DMG_PATH" | awk '{print $1}')
COMMIT_SHA=$(git rev-parse HEAD)
SPARKLE_APPCAST_SHA=""
SPARKLE_APPCAST_SIZE=""
SPARKLE_BRIDGE_APPCAST_PATH=""
SPARKLE_BRIDGE_APPCAST_SHA=""
SPARKLE_BRIDGE_APPCAST_SIZE=""
if [ -n "${SPARKLE_APPCAST_PATH:-}" ] && [ -f "$SPARKLE_APPCAST_PATH" ]; then
    SPARKLE_APPCAST_SHA=$(/usr/bin/shasum -a 256 "$SPARKLE_APPCAST_PATH" | awk '{print $1}')
    SPARKLE_APPCAST_SIZE=$(/usr/bin/stat -f %z "$SPARKLE_APPCAST_PATH")
fi
if [ -n "$SPARKLE_BRIDGE_APPCAST_FILENAME" ]; then
    SPARKLE_BRIDGE_APPCAST_PATH="${SPARKLE_APPCAST_DIR}/${SPARKLE_BRIDGE_APPCAST_FILENAME}"
    if [ -f "$SPARKLE_BRIDGE_APPCAST_PATH" ]; then
        SPARKLE_BRIDGE_APPCAST_SHA=$(/usr/bin/shasum -a 256 "$SPARKLE_BRIDGE_APPCAST_PATH" | awk '{print $1}')
        SPARKLE_BRIDGE_APPCAST_SIZE=$(/usr/bin/stat -f %z "$SPARKLE_BRIDGE_APPCAST_PATH")
    else
        SPARKLE_BRIDGE_APPCAST_PATH=""
    fi
fi

cat >"$METADATA_PATH" <<EOF
version=${VERSION}
build_number=${SPARKLE_BUILD_NUMBER}
channel=${CHANNEL}
git_commit=${COMMIT_SHA}
signing_identity=<redacted>
team_id=<redacted>
notary_profile=<redacted>
sparkle_feed_url=${SPARKLE_FEED_URL}
github_release_tag=${GITHUB_RELEASE_TAG}
recover_existing_release=${RECOVER_EXISTING_RELEASE}
sparkle_publish_release=${SPARKLE_PUBLISH_RELEASE}
sparkle_bridge_publish_release=${SPARKLE_BRIDGE_PUBLISH_RELEASE}
sparkle_bridge_appcast_filename=${SPARKLE_BRIDGE_APPCAST_FILENAME}
prerelease_prune_enabled=${PRERELEASE_PRUNE_ENABLED}
prerelease_prune_keep=${PRERELEASE_PRUNE_KEEP}
prerelease_prune_report_path=$(relative_to_project_root "${PRERELEASE_PRUNE_REPORT_PATH:-}")
archive_path=$(relative_to_project_root "$ARCHIVE_PATH")
app_path=$(relative_to_project_root "$SIGNED_APP_PATH")
release_app_path=$(relative_to_project_root "$RELEASE_APP_PATH")
DMG_PATH=$(relative_to_project_root "$DMG_PATH")
dmg_sha256=${DMG_SHA}
sparkle_appcast_path=$(relative_to_project_root "${SPARKLE_APPCAST_PATH:-}")
sparkle_appcast_sha256=${SPARKLE_APPCAST_SHA}
sparkle_appcast_size=${SPARKLE_APPCAST_SIZE}
sparkle_bridge_appcast_path=$(relative_to_project_root "${SPARKLE_BRIDGE_APPCAST_PATH}")
sparkle_bridge_appcast_sha256=${SPARKLE_BRIDGE_APPCAST_SHA}
sparkle_bridge_appcast_size=${SPARKLE_BRIDGE_APPCAST_SIZE}
app_notary_log=$(relative_to_project_root "$APP_NOTARY_LOG")
dmg_notary_log=$(relative_to_project_root "$DMG_NOTARY_LOG")
EOF

printf 'Release complete:\n'
printf '  Unsigned candidate: %s\n' "$RELEASE_APP_PATH"
printf '  Signed app: %s\n' "$SIGNED_APP_PATH"
printf '  DMG: %s\n' "$DMG_PATH"
if [ -n "${SPARKLE_APPCAST_PATH:-}" ]; then
    printf '  Sparkle appcast: %s\n' "$SPARKLE_APPCAST_PATH"
fi
printf '  Metadata: %s\n' "$METADATA_PATH"
