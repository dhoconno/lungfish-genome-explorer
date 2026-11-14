#!/bin/bash
# Cut the RNA-seq test fixtures of Tests/Fixtures/rnaseq from the data of Phase 5.0.
#
# Usage: cut.sh <data_root> <out_dir>
#   data_root  the RNA-seq data root, /Volumes/lge_scratch/lge/rnaseq on galah
#   out_dir    a new or empty folder that receives the fixtures, SOURCES.tsv and SHA256SUMS
#
#   PYTHON     the interpreter (default /opt/homebrew/bin/python3). The gzip bytes of the
#              Cell Ranger cut come from its zlib, so the pinned sums hold for that build.
#
# The sources are pinned by sha256 in cut.py, which stops on a changed source. Two runs
# write the same bytes, and Tests/Fixtures/rnaseq holds one run plus its README.md.
# It reads about 120 MB and runs at nice 15.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    sed -n '4,9p' "$0" >&2
    exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-/opt/homebrew/bin/python3}
exec nice -n 15 "$PYTHON" -I "$HERE/cut.py" "$1" "$2"
