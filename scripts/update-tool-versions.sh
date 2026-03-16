#!/bin/bash
#
# update-tool-versions.sh - Check for and apply updates to bundled tool versions
#
# Reads tool-versions.json, queries GitHub Releases API for each tool,
# and reports or applies version updates.
#
# Usage:
#   ./scripts/update-tool-versions.sh --check       # Check for updates (dry run)
#   ./scripts/update-tool-versions.sh --update       # Update manifest + Swift source
#   ./scripts/update-tool-versions.sh --rebuild      # Update + rebuild tools
#
# Options:
#   --check         Check for updates only (default)
#   --update        Update tool-versions.json with latest versions
#   --rebuild       Update manifest and run bundle-native-tools.sh
#   --tool <name>   Check/update a specific tool only
#   --json          Output check results as JSON
#   --help          Show this help message
#
# Environment:
#   GITHUB_TOKEN    Optional. Use for higher API rate limits (60/hr unauthenticated,
#                   5000/hr with token). Set via: export GITHUB_TOKEN=ghp_...
#
# Designed for monthly cron:
#   0 9 1 * * cd /path/to/lungfish && ./scripts/update-tool-versions.sh --check --json >> /var/log/lungfish-updates.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
THIRD_PARTY_NOTICES="$PROJECT_ROOT/THIRD-PARTY-NOTICES"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
MODE="check"
SPECIFIC_TOOL=""
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --check)   MODE="check"; shift ;;
        --update)  MODE="update"; shift ;;
        --rebuild) MODE="rebuild"; shift ;;
        --tool)    SPECIFIC_TOOL="$2"; shift 2 ;;
        --json)    JSON_OUTPUT=true; shift ;;
        --help)    head -30 "$0" | tail -25; exit 0 ;;
        *)         echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Verify manifest exists
if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}Error: tool-versions.json not found at $MANIFEST${NC}" >&2
    exit 1
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required. Install with: brew install jq${NC}" >&2
    exit 1
fi

# GitHub API helper
github_api() {
    local url="$1"
    local auth_header=""
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header="-H \"Authorization: Bearer $GITHUB_TOKEN\""
    fi
    eval curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$auth_header" \
        "\"$url\""
}

# Get latest release version from GitHub
# Returns the tag name stripped of leading "v"
get_latest_github_version() {
    local owner="$1"
    local repo="$2"

    local response
    response=$(github_api "https://api.github.com/repos/$owner/$repo/releases/latest" 2>/dev/null || echo "{}")

    local tag
    tag=$(echo "$response" | jq -r '.tag_name // empty' 2>/dev/null)

    if [ -z "$tag" ]; then
        # Try tags endpoint as fallback (some repos don't use GitHub Releases)
        response=$(github_api "https://api.github.com/repos/$owner/$repo/tags?per_page=1" 2>/dev/null || echo "[]")
        tag=$(echo "$response" | jq -r '.[0].name // empty' 2>/dev/null)
    fi

    if [ -z "$tag" ]; then
        echo ""
        return
    fi

    # Strip leading "v" or "V" if present
    echo "$tag" | sed 's/^[vV]//'
}

# Parse GitHub owner/repo from sourceUrl
parse_github_repo() {
    local url="$1"
    # Extract owner/repo from https://github.com/owner/repo
    echo "$url" | sed -n 's|https://github.com/\([^/]*\)/\([^/]*\).*|\1/\2|p'
}

# Compare version strings (returns: "newer", "same", "older", or "unknown")
compare_versions() {
    local current="$1"
    local latest="$2"

    if [ "$current" = "$latest" ]; then
        echo "same"
        return
    fi

    # Use sort -V for version comparison
    local sorted
    sorted=$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)

    if [ "$sorted" = "$latest" ] && [ "$sorted" != "$current" ]; then
        echo "newer"
    else
        echo "older"
    fi
}

# Read current tool info from manifest
read_tool_info() {
    local tool_name="$1"
    jq -r ".tools[] | select(.name == \"$tool_name\") | \"\(.version)|\(.sourceUrl)|\(.displayName)|\(.provisioningMethod)\"" "$MANIFEST"
}

# Main check logic
check_updates() {
    local updates_found=0
    local json_results="[]"

    local tool_names
    if [ -n "$SPECIFIC_TOOL" ]; then
        tool_names="$SPECIFIC_TOOL"
    else
        tool_names=$(jq -r '.tools[].name' "$MANIFEST")
    fi

    if ! $JSON_OUTPUT; then
        echo -e "${BLUE}Checking for tool version updates...${NC}"
        echo ""
        printf "%-30s %-12s %-12s %s\n" "Tool" "Current" "Latest" "Status"
        printf "%-30s %-12s %-12s %s\n" "----" "-------" "------" "------"
    fi

    for tool_name in $tool_names; do
        local info
        info=$(read_tool_info "$tool_name")

        if [ -z "$info" ]; then
            if ! $JSON_OUTPUT; then
                echo -e "  ${RED}$tool_name: not found in manifest${NC}"
            fi
            continue
        fi

        local current_version source_url display_name provisioning
        current_version=$(echo "$info" | cut -d'|' -f1)
        source_url=$(echo "$info" | cut -d'|' -f2)
        display_name=$(echo "$info" | cut -d'|' -f3)
        provisioning=$(echo "$info" | cut -d'|' -f4)

        # Parse GitHub repo
        local repo_path
        repo_path=$(parse_github_repo "$source_url")

        local latest_version=""
        local status_text=""

        # Special handling for tools with non-standard release patterns
        case "$tool_name" in
            ucsc-tools)
                # UCSC tools don't use GitHub Releases; skip auto-check
                latest_version=""
                ;;
            openjdk)
                # Temurin releases are in adoptium/temurin21-binaries, tags like "jdk-21.0.10+1"
                local temurin_tag
                temurin_tag=$(github_api "https://api.github.com/repos/adoptium/temurin21-binaries/releases/latest" 2>/dev/null \
                    | jq -r '.tag_name // empty')
                if [ -n "$temurin_tag" ]; then
                    # Extract version from "jdk-21.0.10+1" -> "21.0.10"
                    latest_version=$(echo "$temurin_tag" | sed 's/^jdk-//; s/+.*//')
                fi
                ;;
            cutadapt)
                # cutadapt PyPI releases may differ from GitHub tags
                latest_version=$(github_api "https://api.github.com/repos/marcelm/cutadapt/releases/latest" 2>/dev/null \
                    | jq -r '.tag_name // empty' | sed 's/^v//')
                ;;
            bbtools)
                # BBTools is on SourceForge, not GitHub; skip auto-check
                latest_version=""
                ;;
            *)
                if [ -n "$repo_path" ]; then
                    local owner repo
                    owner=$(echo "$repo_path" | cut -d'/' -f1)
                    repo=$(echo "$repo_path" | cut -d'/' -f2)
                    latest_version=$(get_latest_github_version "$owner" "$repo")
                fi
                ;;
        esac

        if [ -z "$latest_version" ]; then
            status_text="skip (no GitHub releases)"
            if ! $JSON_OUTPUT; then
                printf "%-30s %-12s %-12s ${YELLOW}%s${NC}\n" "$display_name" "$current_version" "?" "$status_text"
            fi
            json_results=$(echo "$json_results" | jq --arg name "$tool_name" --arg cur "$current_version" \
                '. + [{"name": $name, "current": $cur, "latest": null, "status": "skipped"}]')
            continue
        fi

        local comparison
        comparison=$(compare_versions "$current_version" "$latest_version")

        case "$comparison" in
            same)
                status_text="up to date"
                if ! $JSON_OUTPUT; then
                    printf "%-30s %-12s %-12s ${GREEN}%s${NC}\n" "$display_name" "$current_version" "$latest_version" "$status_text"
                fi
                ;;
            newer)
                status_text="UPDATE AVAILABLE"
                updates_found=$((updates_found + 1))
                if ! $JSON_OUTPUT; then
                    printf "%-30s %-12s %-12s ${CYAN}%s${NC}\n" "$display_name" "$current_version" "$latest_version" "$status_text"
                fi
                ;;
            *)
                status_text="current is newer"
                if ! $JSON_OUTPUT; then
                    printf "%-30s %-12s %-12s ${YELLOW}%s${NC}\n" "$display_name" "$current_version" "$latest_version" "$status_text"
                fi
                ;;
        esac

        json_results=$(echo "$json_results" | jq \
            --arg name "$tool_name" \
            --arg cur "$current_version" \
            --arg lat "$latest_version" \
            --arg stat "$comparison" \
            '. + [{"name": $name, "current": $cur, "latest": $lat, "status": $stat}]')

        # Rate limit: 0.5s between API calls
        sleep 0.5
    done

    if $JSON_OUTPUT; then
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "$json_results" | jq --arg ts "$timestamp" --arg count "$updates_found" \
            '{"timestamp": $ts, "updatesAvailable": ($count | tonumber), "tools": .}'
    else
        echo ""
        if [ $updates_found -gt 0 ]; then
            echo -e "${CYAN}$updates_found update(s) available.${NC}"
            echo -e "Run ${GREEN}$0 --update${NC} to update the manifest."
        else
            echo -e "${GREEN}All tools are up to date.${NC}"
        fi
    fi

}

# Apply updates to the manifest
apply_updates() {
    local tool_names
    if [ -n "$SPECIFIC_TOOL" ]; then
        tool_names="$SPECIFIC_TOOL"
    else
        tool_names=$(jq -r '.tools[].name' "$MANIFEST")
    fi

    local updated_count=0

    echo -e "${BLUE}Updating tool versions...${NC}"
    echo ""

    for tool_name in $tool_names; do
        local info
        info=$(read_tool_info "$tool_name")
        [ -z "$info" ] && continue

        local current_version source_url display_name
        current_version=$(echo "$info" | cut -d'|' -f1)
        source_url=$(echo "$info" | cut -d'|' -f2)
        display_name=$(echo "$info" | cut -d'|' -f3)

        local repo_path
        repo_path=$(parse_github_repo "$source_url")
        [ -z "$repo_path" ] && continue

        local owner repo
        owner=$(echo "$repo_path" | cut -d'/' -f1)
        repo=$(echo "$repo_path" | cut -d'/' -f2)
        local latest_version
        latest_version=$(get_latest_github_version "$owner" "$repo")

        [ -z "$latest_version" ] && continue

        local comparison
        comparison=$(compare_versions "$current_version" "$latest_version")

        if [ "$comparison" = "newer" ]; then
            echo -e "  ${CYAN}$display_name${NC}: $current_version -> ${GREEN}$latest_version${NC}"

            # Update the version in the manifest
            local tmp_manifest
            tmp_manifest=$(mktemp)
            jq --arg name "$tool_name" --arg ver "$latest_version" \
                '(.tools[] | select(.name == $name)).version = $ver' \
                "$MANIFEST" > "$tmp_manifest"
            mv "$tmp_manifest" "$MANIFEST"

            updated_count=$((updated_count + 1))
        fi

        sleep 0.5
    done

    if [ $updated_count -gt 0 ]; then
        # Update the lastUpdated timestamp
        local tmp_manifest
        tmp_manifest=$(mktemp)
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq --arg ts "$timestamp" '.lastUpdated = $ts' "$MANIFEST" > "$tmp_manifest"
        mv "$tmp_manifest" "$MANIFEST"

        echo ""
        echo -e "${GREEN}Updated $updated_count tool(s) in tool-versions.json${NC}"

        # Regenerate VERSIONS.txt
        regenerate_versions_txt

        # Update THIRD-PARTY-NOTICES version numbers
        update_third_party_notices

        echo ""
        echo -e "${YELLOW}Next steps:${NC}"
        echo "  1. Review changes: git diff"
        echo "  2. Rebuild tools:  ./scripts/bundle-native-tools.sh"
        echo "  3. Run tests:      swift test"
        echo "  4. Commit:         git commit -am 'Update embedded tool versions'"
    else
        echo ""
        echo -e "${GREEN}No updates to apply.${NC}"
    fi
}

# Regenerate VERSIONS.txt from tool-versions.json
regenerate_versions_txt() {
    local versions_file
    versions_file="$(dirname "$MANIFEST")/VERSIONS.txt"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    local arch
    arch=$(jq -r '.buildArchitecture' "$MANIFEST")

    cat > "$versions_file" << HEADER
Lungfish Bundled Bioinformatics Tools
======================================

This directory contains pre-built bioinformatics tools bundled with Lungfish.
All tools are open source and distributed under MIT-compatible licenses.

Versions:
HEADER

    jq -r '.tools[] | "- \(.displayName): \(.version) (\(.license) license)"' "$MANIFEST" >> "$versions_file"

    cat >> "$versions_file" << FOOTER

Build date: $timestamp
Build architecture: $arch

Source URLs:
FOOTER

    jq -r '.tools[] | "- \(.name): \(.sourceUrl)"' "$MANIFEST" >> "$versions_file"

    cat >> "$versions_file" << LICENSES

Licenses:
LICENSES

    jq -r '.tools[] | "- \(.name): \(.licenseUrl)"' "$MANIFEST" >> "$versions_file"

    echo -e "  ${GREEN}Regenerated VERSIONS.txt${NC}"
}

# Update version numbers in THIRD-PARTY-NOTICES
update_third_party_notices() {
    if [ ! -f "$THIRD_PARTY_NOTICES" ]; then
        echo -e "  ${YELLOW}THIRD-PARTY-NOTICES not found, skipping${NC}"
        return
    fi

    # For each tool, update the version in the header line
    local tool_count
    tool_count=$(jq '.tools | length' "$MANIFEST")

    for ((i=0; i<tool_count; i++)); do
        local name version display_name
        name=$(jq -r ".tools[$i].name" "$MANIFEST")
        version=$(jq -r ".tools[$i].version" "$MANIFEST")
        display_name=$(jq -r ".tools[$i].displayName" "$MANIFEST")

        # Update lines like "SAMtools 1.22.1" to "SAMtools 1.23"
        # Match display name followed by a version-like string
        if command -v gsed &>/dev/null; then
            gsed -i "s/^$display_name [0-9][0-9.]*/$display_name $version/" "$THIRD_PARTY_NOTICES"
        else
            sed -i '' "s/^$display_name [0-9][0-9.]*/$display_name $version/" "$THIRD_PARTY_NOTICES"
        fi
    done

    echo -e "  ${GREEN}Updated THIRD-PARTY-NOTICES version numbers${NC}"
}

# Main
case "$MODE" in
    check)
        check_updates
        ;;
    update)
        apply_updates
        ;;
    rebuild)
        apply_updates
        echo ""
        echo -e "${BLUE}Rebuilding tools...${NC}"
        "$SCRIPT_DIR/bundle-native-tools.sh"
        ;;
esac
