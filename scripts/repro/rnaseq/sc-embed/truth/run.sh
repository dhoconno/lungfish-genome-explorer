#!/usr/bin/env bash
# Writes the script truth of sub-phase 5.5 for the import, the gene values and the selection (lane CM-TRUTH).
#
# Usage: bash scripts/repro/rnaseq/sc-embed/truth/run.sh
#   DATA           data root, default /Volumes/lge_scratch/lge/rnaseq
#   OUT            truth folder, default $DATA/work/sc-embed/truth
#   PY             python of the main environment, default $DATA/env/bin/python, always run with -I
#   SEURAT_ENV     R environment that holds Seurat 5.5.1, default $DATA/env-r-seurat
#   NO_LEDGER=1    leave out the ledger rows, for a development run
#   UPDATE_CLAIMS=1 copy this run's claims.tsv over the committed one
#
# truth.py writes a new folder beside OUT. When OUT exists the script compares the two SHA256SUMS files, so a second run
# prints TRUTH EQUAL or lists what differs and never overwrites OUT. Python and R run at nice -n 15.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../../.." && pwd)
DATA=${DATA:-/Volumes/lge_scratch/lge/rnaseq}
OUT=${OUT:-$DATA/work/sc-embed/truth}
PY=${PY:-$DATA/env/bin/python}
SEURAT_ENV=${SEURAT_ENV:-$DATA/env-r-seurat}
export PYTHONHASHSEED=0

mkdir -p "$(dirname "$OUT")"
STAGE="$OUT.run-$$"
rm -rf "$STAGE"
rc=0
nice -n 15 "$PY" -I "$HERE/truth.py" "$DATA" "$REPO" "$STAGE" "$SEURAT_ENV" || rc=$?
if [ "$rc" != 0 ]; then
  echo "run.sh: truth.py ended with status $rc, and $STAGE is left for a look" >&2
  exit "$rc"
fi

files=$(wc -l < "$STAGE/SHA256SUMS" | tr -d ' ')
if [ -d "$OUT" ]; then
  if cmp -s "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS"; then
    echo "TRUTH EQUAL: $files files, and every sha256 equals the one in $OUT"
    rm -rf "$STAGE"
  else
    echo "TRUTH DIFFERS from $OUT, and $STAGE is left for a look" >&2
    diff "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS" >&2 || true
    exit 1
  fi
else
  mv "$STAGE" "$OUT"
  echo "TRUTH WRITTEN: $files files in $OUT"
fi

if cmp -s "$OUT/claims.tsv" "$HERE/claims.tsv"; then
  echo "CLAIMS EQUAL"
elif [ "${UPDATE_CLAIMS:-}" = 1 ]; then
  cp "$OUT/claims.tsv" "$HERE/claims.tsv"
  echo "CLAIMS UPDATED"
else
  echo "CLAIMS DIFFER from the committed claims.tsv, set UPDATE_CLAIMS=1 to copy this run's" >&2
fi

if [ "${NO_LEDGER:-}" != 1 ]; then
  "$PY" -I "$HERE/ledger.py" "$DATA" "$OUT" CM-TRUTH
fi
