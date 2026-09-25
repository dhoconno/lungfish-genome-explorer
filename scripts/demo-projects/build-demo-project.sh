#!/usr/bin/env bash
# Build one downloadable LGE demo project (or all of them), zip it
# deterministically, verify the zip, and update demo-projects.manifest.json.
#
# Usage:
#   scripts/demo-projects/build-demo-project.sh <id[,id...]|all> <out-dir> [options]
#
# Options (passed through to build_demo_project.py):
#   --cli PATH        lungfish-cli to drive. Default $LUNGFISH_CLI, else
#                     /Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli
#   --cache-dir DIR   folder of already-downloaded SRA runs (<run>_1.fastq[.gz],
#                     <run>_2.fastq[.gz]). Repeatable. Missing runs are fetched
#                     with `lungfish-cli fetch sra download`.
#   --work-dir DIR    staging, build, and verify root (default /tmp/lge-demo-build)
#   --version VER     demo project version (default 2026.9.44)
#   --no-verify       skip the unzip-and-inspect check
#   --no-manifest     leave demo-projects.manifest.json alone
#
# Ids: genes-and-sequences human-reads human-mapping-and-variants
#      long-reads-and-assembly sarscov2-amplicons pathogen-detection
#      mhc-genotyping twelve-s-metabarcoding
#
# The hg002 fixtures live in the pinned manual-media repo. Fetch them first:
#   bash docs/user-manual/build/scripts/fetch-media.sh
set -euo pipefail

if [ "$#" -lt 2 ]; then
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ID="$1"
OUT="$2"
shift 2
exec python3 "$HERE/build_demo_project.py" "$ID" --out-dir "$OUT" "$@"
