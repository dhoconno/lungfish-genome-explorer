#!/bin/bash
#
# sanitize-bundled-tools.sh
#
# Release packaging helper that removes executable permissions from copied tool
# resources that are not actual macOS executables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INCLUDE_WORKTREES="${LUNGFISH_SANITIZE_INCLUDE_WORKTREES:-0}"
ADHOC_SEAL=0
declare -a BUILDER_ROOTS=()

usage() {
    echo "Usage: $0 [--adhoc-seal] <path> [<path> ...]" >&2
}

if [ "${1:-}" = "--adhoc-seal" ]; then
    ADHOC_SEAL=1
    shift
fi

if [ "$#" -lt 1 ]; then
    usage
    exit 64
fi

append_path_rewrite() {
    [ -n "$1" ] || return 0
    PATH_REWRITES+=("$1" "$2")
}

append_builder_root() {
    local candidate="$1"

    [ -n "$candidate" ] || return 0
    [ -d "$candidate" ] || return 0
    candidate="$(cd "$candidate" && pwd)"

    local existing
    if [ "${#BUILDER_ROOTS[@]}" -gt 0 ]; then
        for existing in "${BUILDER_ROOTS[@]}"; do
            if [ "$existing" = "$candidate" ]; then
                return 0
            fi
        done
    fi

    BUILDER_ROOTS+=("$candidate")
}

initialize_builder_roots() {
    append_builder_root "$PROJECT_ROOT"

    case "$INCLUDE_WORKTREES" in
        1|true|TRUE|yes|YES)
            ;;
        *)
            return
            ;;
    esac

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
    local -a PATH_REWRITES=()

    for builder_root in "${BUILDER_ROOTS[@]}"; do
        append_path_rewrite \
            "${builder_root}/.build/xcode-cli-release/" \
            "/swiftpm-build/"
        append_path_rewrite \
            "${builder_root}/.build/xcode-cli/" \
            "/swiftpm-build/"
        append_path_rewrite \
            "${builder_root}/.build/tools/" \
            "/lungfish-tools-build/"
        append_path_rewrite \
            "${builder_root}/" \
            "/workspace/"
    done

    append_path_rewrite \
        "/workspace/.build/xcode-cli-release/" \
        "/swiftpm-build/"
    append_path_rewrite \
        "/workspace/.build/xcode-cli/" \
        "/swiftpm-build/"
    append_path_rewrite \
        "/workspace/.build/tools/" \
        "/lungfish-tools-build/"
    append_path_rewrite \
        "/Users/dho/Documents/ncbi-vdb/" \
        "/ncbi-vdb-src/"

    append_path_rewrite \
        "/opt/homebrew/" \
        "/opt/portable/"
    append_path_rewrite \
        "/usr/local/Cellar/" \
        "/usr/local/pkgdir/"
    append_path_rewrite \
        "/usr/local/etc/" \
        "/usr/local/cfg/"

    # Vendored Mach-O tools can carry upstream CI builder paths that are not
    # derived from this checkout (for example conda's /Users/runner roots).
    # The replacement is exactly the same byte length, preserving every
    # following string offset while removing the machine-specific home prefix.
    append_path_rewrite \
        "/Users/" \
        "/build/"

    # Slurp binary bytes once, then apply the same ordered fixed-width rewrites.
    # NUL-delimited Perl -0 processing performs millions of record iterations
    # on debug-bearing Mach-O files. Do not rewrite an already portable file.
    perl -0777 -e '
        use strict;
        use warnings;
        use bytes;
        my $path = shift @ARGV;
        die "unpaired path rewrite\n" if @ARGV % 2;
        open my $input, "<:raw", $path or die "read sanitizer input: $!\n";
        my $data = <$input>;
        die "read sanitizer input: $!\n" unless defined $data;
        close $input or die "close sanitizer input: $!\n";
        my $changed = 0;
        while (@ARGV) {
            my ($source, $replacement) = splice @ARGV, 0, 2;
            if (length($replacement) > length($source)) {
                die "replacement is longer than source prefix\n";
            }
            my $padded = $replacement . ("\0" x (length($source) - length($replacement)));
            $changed += ($data =~ s/\Q$source\E/$padded/g);
        }
        if ($changed) {
            open my $output, "+<:raw", $path or die "write sanitizer output: $!\n";
            print {$output} $data or die "write sanitizer output: $!\n";
            close $output or die "close sanitizer output: $!\n";
        }
    ' -- "$path" "${PATH_REWRITES[@]}"
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

    if [ ! -x "$path" ]; then
        return
    fi

    local file_type
    file_type=$(/usr/bin/file -b "$path")

    case "$file_type" in
        Mach-O*)
            rewrite_embedded_builder_paths "$path"
            if [ "$ADHOC_SEAL" -eq 1 ]; then
                # arm64 macOS kills a transformed Mach-O whose previous code
                # signature is no longer valid. This identity-free seal uses no
                # credential and is replaced by Developer ID only after the
                # candidate receipt has been verified.
                /usr/bin/codesign --force --sign - --timestamp=none "$path" >/dev/null
                /usr/bin/codesign --verify --strict "$path"
            fi
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
