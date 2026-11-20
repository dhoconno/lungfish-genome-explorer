#!/usr/bin/env bash
# Check that an exported seurat.R keeps the samples of a result apart (check X5 of sub-phase 5.5, lane CM-IDENT).
#
# Usage: template_ident.sh LUNGFISH_CLI [WORK_DIR]
#
#   LUNGFISH_CLI  a built lungfish-cli, for example .build/debug/lungfish-cli
#   WORK_DIR      optional, a folder that does not exist yet, for the fixture and the export (default a new folder in TMPDIR)
#
# Step 1 copies the 200-cell STARsolo cut of pbmc_1k_v3 (Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3) under four sample ids and
# imports the four folders, in this order, as one single-cell result. cov_10 and cov_11 share the part before their first "_",
# which Seurat reads as the identity of a cell named cov_10_<barcode>. ax.1 holds a dot. Bx puts a capital beside ax, so R sorts
# the ids one way under LC_COLLATE=C and another under en_US.UTF-8, and neither is the order of samples.tsv.
# Step 2 exports the result with lungfish-cli rnaseq export.
# Step 3 runs the exported seurat.R in env-r-seurat twice, with LC_COLLATE=C and with LC_COLLATE=en_US.UTF-8, and then a probe
# in the same R session. The probe reports the levels of orig.ident and of Idents and writes one row a cell from the object.
# Step 4 checks each run against cells.sqlite of the result. The ordered levels of orig.ident and of Idents equal the order of
# samples.tsv, which equals the order of cells.sqlite. meta.data holds a barcode column, and each cell's row names its sample and
# its barcode as cells.sqlite holds them. R has to report the collation it was asked for.
# Step 5 runs scanpy.py in the Python environment and checks that obs["sample"] and obs["barcode"] hold the same pairs.
#
# It prints IDENT OK <n> samples when every check holds. Otherwise it prints each mismatch with the line it expected and the line
# it got, and keeps the work folder.
#
# Environment variables
#   SEURAT_ENV  prefix of the R environment with Seurat (default /Volumes/lge_scratch/lge/rnaseq/env-r-seurat)
#   PYTHON_ENV  prefix of the environment with scanpy (default /Volumes/lge_scratch/lge/rnaseq/env)
#   KEEP=1      keep the work folder after a pass (it is always kept after a failure)
#
# Exit status is 0 when every check passed, 1 when one failed and 2 for a usage error. The script targets bash 3.2.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then sed -n '2,3p' "$0" >&2; exit 2; fi
[ -x "$1" ] || { echo "no lungfish-cli at $1" >&2; exit 2; }
CLI="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
CUT="$REPO/Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3"
SEURAT_ENV="${SEURAT_ENV:-/Volumes/lge_scratch/lge/rnaseq/env-r-seurat}"
PYTHON_ENV="${PYTHON_ENV:-/Volumes/lge_scratch/lge/rnaseq/env}"
SQLITE=/usr/bin/sqlite3
[ -x "$SQLITE" ] || SQLITE=sqlite3
IDS="cov_10 cov_11 ax.1 Bx"
TAB=$(printf '\t')

[ -d "$CUT" ] || { echo "no fixture at $CUT" >&2; exit 2; }
[ -x "$SEURAT_ENV/bin/Rscript" ] || { echo "no Rscript in $SEURAT_ENV, set SEURAT_ENV" >&2; exit 2; }
[ -x "$PYTHON_ENV/bin/python" ] || { echo "no python in $PYTHON_ENV, set PYTHON_ENV" >&2; exit 2; }
if [ "$#" -eq 2 ]; then
  if [ -e "$2" ]; then echo "$2 exists, name a folder that does not" >&2; exit 2; fi
  mkdir -p "$2" || exit 2
  WORK=$(cd "$2" && pwd)
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/template-ident.XXXXXX") || exit 2
fi

FAILED=0
miss() { echo "MISMATCH $*"; FAILED=1; }
# expect_line LOG WHAT WANTED: WANTED is one whole line of LOG, tab separated. A miss prints it with the lines LOG holds of its kind.
expect_line() {
  if grep -Fx -- "$3" "$1" > /dev/null; then return 0; fi
  miss "$2"
  echo "  expected: $(printf '%s' "$3" | tr '\t' ' ')"
  echo "  got:      $(grep -F -- "${3%%"$TAB"*}${TAB}$(printf '%s' "$3" | cut -f2)" "$1" | head -1 | tr '\t' ' ')"
}

# ---- Steps 1 and 2: the fixture, the import and the export ----
mkdir -p "$WORK/runs" "$WORK/project.lungfish"
INPUTS=()
for id in $IDS; do
  cp -R "$CUT" "$WORK/runs/$id" || exit 1
  INPUTS+=("$WORK/runs/$id")
done
if ! "$CLI" import rnaseq "${INPUTS[@]}" --project "$WORK/project.lungfish" --name ident > "$WORK/import.log" 2>&1; then
  echo "the import failed, see $WORK/import.log" >&2; tail -5 "$WORK/import.log" >&2; exit 1
fi
RESULT="$WORK/project.lungfish/Analyses/ident.lungfishrnaseq"
if ! "$CLI" rnaseq export "$RESULT" --output "$WORK/export" > "$WORK/export.log" 2>&1; then
  echo "the export failed, see $WORK/export.log" >&2; tail -5 "$WORK/export.log" >&2; exit 1
fi

# ---- What cells.sqlite holds: the samples in order, and a row (cell name, sample, barcode) a cell ----
DB="$RESULT/cells.sqlite"
"$SQLITE" -readonly "$DB" "SELECT name FROM samples ORDER BY sample;" > "$WORK/expect.samples" || exit 1
"$SQLITE" -readonly -separator "$TAB" "$DB" \
  "SELECT s.name || '_' || c.barcode, s.name, c.barcode FROM cells c JOIN samples s ON s.sample = c.sample;" \
  | LC_ALL=C sort > "$WORK/expect.cells"
N=$(wc -l < "$WORK/expect.samples" | tr -d ' ')
CELLS=$(wc -l < "$WORK/expect.cells" | tr -d ' ')
if [ "$N" -ne 4 ] || [ "$CELLS" -lt 1 ]; then echo "cells.sqlite holds $N samples and $CELLS cells" >&2; exit 1; fi
# A cell's row in the object is (cell name, orig.ident, Idents, sample, barcode), and the three identities are the sample.
awk -F"$TAB" -v OFS="$TAB" '{ print $1, $2, $2, $2, $3 }' "$WORK/expect.cells" | LC_ALL=C sort > "$WORK/expect.rows"
WANT_LEVELS=$(paste -sd "$TAB" "$WORK/expect.samples")

tail -n +2 "$WORK/export/samples.tsv" | cut -f1 > "$WORK/samples.tsv.ids"
if ! cmp -s "$WORK/samples.tsv.ids" "$WORK/expect.samples"; then
  miss "samples.tsv lists $(paste -sd ' ' "$WORK/samples.tsv.ids") and cells.sqlite lists $(paste -sd ' ' "$WORK/expect.samples")"
fi

# ---- Steps 3 and 4: seurat.R and a probe, under two collations ----
cat > "$WORK/probe.R" <<'EOF'
# Written by template_ident.sh. It runs after seurat.R in the same R session and reports what the Seurat object holds.
meta <- object[[]]
who <- Seurat::Idents(object)
say <- function(...) cat(paste(c(...), collapse = "\t"), "\n", sep = "")
say("IDENT-COLLATE", Sys.getlocale("LC_COLLATE"))
say("IDENT-LEVELS", "orig.ident", levels(meta[["orig.ident"]]))
say("IDENT-LEVELS", "Idents", levels(who))
say("IDENT-COLUMNS", names(meta))
rows <- data.frame(cell = rownames(meta), orig.ident = as.character(meta[["orig.ident"]]), ident = as.character(who[rownames(meta)]),
                   sample = as.character(meta[["sample"]]), barcode = if ("barcode" %in% names(meta)) as.character(meta[["barcode"]]) else NA_character_,
                   stringsAsFactors = FALSE)
write.table(rows, Sys.getenv("IDENT_ROWS"), sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE)
EOF

for collate in C en_US.UTF-8; do
  log="$WORK/seurat.$collate.log"
  rows="$WORK/seurat.$collate.rows"
  rm -f "$rows"
  (cd "$WORK/export" && env -u LC_ALL LC_COLLATE="$collate" IDENT_ROWS="$rows" IDENT_PROBE="$WORK/probe.R" PATH="$SEURAT_ENV/bin:$PATH" \
    "$SEURAT_ENV/bin/Rscript" --vanilla -e 'source("seurat.R"); source(Sys.getenv("IDENT_PROBE"))') > "$log" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    miss "seurat.R under LC_COLLATE=$collate stopped with status $status, see $log"
    tail -5 "$log"
    continue
  fi
  expect_line "$log" "R did not run under LC_COLLATE=$collate" "IDENT-COLLATE${TAB}${collate}"
  expect_line "$log" "LC_COLLATE=$collate, the levels of orig.ident are not the samples in the order of samples.tsv" "IDENT-LEVELS${TAB}orig.ident${TAB}${WANT_LEVELS}"
  expect_line "$log" "LC_COLLATE=$collate, the levels of Idents are not the samples in the order of samples.tsv" "IDENT-LEVELS${TAB}Idents${TAB}${WANT_LEVELS}"
  if ! grep '^IDENT-COLUMNS' "$log" | tr '\t' '\n' | grep -Fx barcode > /dev/null; then
    miss "LC_COLLATE=$collate, meta.data holds no barcode column, it holds: $(grep '^IDENT-COLUMNS' "$log" | cut -f2- | tr '\t' ' ')"
  fi
  if [ -s "$rows" ]; then
    LC_ALL=C sort "$rows" > "$rows.sorted"
    if ! cmp -s "$rows.sorted" "$WORK/expect.rows"; then
      miss "LC_COLLATE=$collate, a cell's row in the object differs from cells.sqlite (cell, orig.ident, Idents, sample, barcode), first differences:"
      diff "$WORK/expect.rows" "$rows.sorted" | head -6
    fi
  else
    miss "LC_COLLATE=$collate, the probe wrote no rows, see $log"
  fi
done

# ---- Step 5: scanpy.py keeps obs["sample"] and obs["barcode"] ----
cat > "$WORK/probe.py" <<'EOF'
# Written by template_ident.sh. It runs scanpy.py and writes what the AnnData holds, one row a cell.
import os
import runpy

adata = runpy.run_path("scanpy.py", run_name="__main__")["adata"]
print("IDENT-OBS\t" + "\t".join(adata.obs.columns))
with open(os.environ["IDENT_ROWS"], "w") as handle:
    for cell, sample, barcode in zip(adata.obs_names, adata.obs["sample"], adata.obs["barcode"]):
        handle.write("%s\t%s\t%s\n" % (cell, sample, barcode))
EOF
rows="$WORK/scanpy.rows"
rm -f "$rows"
(cd "$WORK/export" && env IDENT_ROWS="$rows" PATH="$PYTHON_ENV/bin:$PATH" "$PYTHON_ENV/bin/python" -I "$WORK/probe.py") > "$WORK/scanpy.log" 2>&1
status=$?
if [ "$status" -ne 0 ] || [ ! -s "$rows" ]; then
  miss "scanpy.py stopped with status $status or its AnnData lacks obs sample or barcode, see $WORK/scanpy.log"
  tail -5 "$WORK/scanpy.log"
elif ! LC_ALL=C sort "$rows" | cmp -s - "$WORK/expect.cells"; then
  miss "the (cell, sample, barcode) rows of the AnnData differ from cells.sqlite, first differences:"
  LC_ALL=C sort "$rows" | diff "$WORK/expect.cells" - | head -6
fi

if [ "$FAILED" -eq 0 ]; then
  echo "IDENT OK $N samples"
  if [ "${KEEP:-0}" != 1 ]; then rm -rf -- "$WORK"; fi
  exit 0
fi
echo "IDENT FAILED, the work folder is kept at $WORK" >&2
exit 1
