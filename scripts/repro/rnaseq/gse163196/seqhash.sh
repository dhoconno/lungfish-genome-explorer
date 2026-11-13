#!/usr/bin/env bash
# Hash the sequence lines (not names, not qualities) of one FASTQ file, to find runs that hold
# the same reads under two accessions. Prints: file, records, md5 of the sequence lines.
# Usage: seqhash.sh <file.fastq.gz> <pigz>
set -euo pipefail
f=$1; PIGZ=$2
"$PIGZ" -dc -p 1 "$f" | awk 'NR % 4 == 2' | tee >(wc -l | tr -d ' ' > "$TMPDIR/$(basename "$f").n") | md5 -q > "$TMPDIR/$(basename "$f").md5"
sleep 1
printf '%s\t%s\t%s\n' "$(basename "$f")" "$(cat "$TMPDIR/$(basename "$f").n")" "$(cat "$TMPDIR/$(basename "$f").md5")"
