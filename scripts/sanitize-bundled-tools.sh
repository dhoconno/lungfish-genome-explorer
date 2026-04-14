#!/bin/bash
#
# sanitize-bundled-tools.sh
#
# Release packaging helper that removes executable permissions from copied tool
# resources that are not actual macOS executables or explicitly launched
# wrapper scripts.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <tools-dir>" >&2
    exit 64
fi

TOOLS_DIR="$1"

if [ ! -d "$TOOLS_DIR" ]; then
    exit 0
fi

is_allowlisted_script() {
    case "$1" in
        bbtools/clumpify.sh|\
        bbtools/bbduk.sh|\
        bbtools/bbmerge.sh|\
        bbtools/repair.sh|\
        bbtools/tadpole.sh|\
        bbtools/reformat.sh|\
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

sanitize_file() {
    local path="$1"
    local relative_path="${path#"$TOOLS_DIR"/}"

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
            chmod 755 "$path"
            ;;
        *)
            chmod 644 "$path"
            ;;
    esac
}

while IFS= read -r -d '' path; do
    sanitize_file "$path"
done < <(/usr/bin/find "$TOOLS_DIR" -type f -print0)
