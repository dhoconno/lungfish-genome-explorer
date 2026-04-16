#!/bin/bash
#
# sanitize-bundled-tools.sh
#
# Release packaging helper that removes executable permissions from copied tool
# resources that are not actual macOS executables or explicitly launched
# wrapper scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
declare -a BUILDER_ROOTS=()

usage() {
    echo "Usage: $0 <path> [<path> ...]" >&2
}

if [ "$#" -lt 1 ]; then
    usage
    exit 64
fi

is_allowlisted_script() {
    case "$1" in
        scrubber/scripts/scrub.sh|\
        scrubber/scripts/cut_spots_fastq.py|\
        scrubber/scripts/fastq_to_fasta.py)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

rewrite_embedded_path_prefix() {
    local path="$1"
    local source_prefix="$2"
    local replacement_prefix="$3"

    if [ -z "$source_prefix" ]; then
        return
    fi

    SOURCE_PREFIX="$source_prefix" REPLACEMENT_PREFIX="$replacement_prefix" perl -0pi -e '
        use strict;
        use warnings;
        use bytes;

        my $source = $ENV{SOURCE_PREFIX};
        my $replacement = $ENV{REPLACEMENT_PREFIX};

        if (length($replacement) > length($source)) {
            die "replacement is longer than source prefix\n";
        }

        my $padded = $replacement . ("\0" x (length($source) - length($replacement)));
        s/\Q$source\E/$padded/g;
    ' "$path"
}

append_builder_root() {
    local candidate="$1"

    [ -n "$candidate" ] || return
    [ -d "$candidate" ] || return
    candidate="$(cd "$candidate" && pwd)"

    local existing
    if [ "${#BUILDER_ROOTS[@]}" -gt 0 ]; then
        for existing in "${BUILDER_ROOTS[@]}"; do
            if [ "$existing" = "$candidate" ]; then
                return
            fi
        done
    fi

    BUILDER_ROOTS+=("$candidate")
}

initialize_builder_roots() {
    append_builder_root "$PROJECT_ROOT"

    if ! command -v git >/dev/null 2>&1; then
        return
    fi

    local line
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                append_builder_root "${line#worktree }"
                ;;
        esac
    done < <(/usr/bin/git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null || true)
}

rewrite_embedded_builder_paths() {
    local path="$1"
    local builder_root

    for builder_root in "${BUILDER_ROOTS[@]}"; do
        rewrite_embedded_path_prefix \
            "$path" \
            "${builder_root}/.build/xcode-cli-release/" \
            "/swiftpm-build/"
        rewrite_embedded_path_prefix \
            "$path" \
            "${builder_root}/.build/xcode-cli/" \
            "/swiftpm-build/"
        rewrite_embedded_path_prefix \
            "$path" \
            "${builder_root}/.build/tools/" \
            "/lungfish-tools-build/"
        rewrite_embedded_path_prefix \
            "$path" \
            "${builder_root}/" \
            "/workspace/"
    done

    rewrite_embedded_path_prefix \
        "$path" \
        "/workspace/.build/xcode-cli-release/" \
        "/swiftpm-build/"
    rewrite_embedded_path_prefix \
        "$path" \
        "/workspace/.build/xcode-cli/" \
        "/swiftpm-build/"
    rewrite_embedded_path_prefix \
        "$path" \
        "/workspace/.build/tools/" \
        "/lungfish-tools-build/"
    rewrite_embedded_path_prefix \
        "$path" \
        "/Users/dho/Documents/ncbi-vdb/" \
        "/ncbi-vdb-src/"
}

sanitize_file() {
    local path="$1"
    local root="$2"
    local relative_path
    if [ -n "$root" ] && [ "$path" != "$root" ]; then
        relative_path="${path#"$root"/}"
    else
        relative_path="$(basename "$path")"
    fi

    if is_allowlisted_script "$relative_path"; then
        chmod 755 "$path"
        return
    fi

    if [ ! -x "$path" ]; then
        return
    fi

    local file_type
    file_type=$(/usr/bin/file -b "$path")

    case "$file_type" in
        Mach-O*)
            rewrite_embedded_builder_paths "$path"
            chmod 755 "$path"
            ;;
        *)
            chmod 644 "$path"
            ;;
    esac
}

sanitize_target() {
    local target="$1"

    if [ ! -e "$target" ]; then
        return
    fi

    if [ -d "$target" ]; then
        while IFS= read -r -d '' path; do
            sanitize_file "$path" "$target"
        done < <(/usr/bin/find "$target" -type f -print0)
        return
    fi

    if [ -f "$target" ]; then
        sanitize_file "$target" "$(dirname "$target")"
    fi
}

initialize_builder_roots

for target in "$@"; do
    sanitize_target "$target"
done
