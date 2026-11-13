#!/usr/bin/env bash
# GSE155673 (Arunachalam 2020), human PBMC CITE-seq in COVID-19, 10x 3' v3, Cell Ranger 3.1:
# STARsolo on cov_10 (8 runs, rulings/SC-SUBSET), compared with its deposited matrix, and the
# cohort claims on the 12 deposited matrices (step A), then again with our cov_10 matrix in
# place of its deposit ("deposited counts, 1 of 12 libraries from LGE reads").
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE155673/{fastq,geo}, studies/_stage_sc, work/tenx-controls
#               (the GRCh38-3.0.0 index and 3M-february-2018 list REPRO-10X built) and MANIFEST.tsv
#   stages      stage inputs index align compare claims (default: all, in that order)
# Environment:
#   LOCKS       folder of the shared heavy lock and PAUSE file ("-" runs heavy steps at once)
#   THREADS     threads for STAR (default 8)
#   INDEX_DIR   STAR index (default <data_root>/work/tenx-controls/index/GRCh38-3.0.0)
#   WHITELIST   barcode list (default <data_root>/work/tenx-controls/whitelist/3M-february-2018.txt)
#   HEAVY_WAIT  minutes one heavy.sh call waits for the lock (default 60); HEAVY_TRIES (48)
#   BAM         1 writes the sorted BAM (default), 0 none; ALIGN_EST_GB disk estimate (40, or 3)
#   KEEP_BAM    1 keeps the BAM after the library passes its close class
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-stage inputs index align compare claims}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$ENVP/bin:$PATH"
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}
IDX=${INDEX_DIR:-$DATA/work/tenx-controls/index/GRCh38-3.0.0}
WL=${WHITELIST:-$DATA/work/tenx-controls/whitelist/3M-february-2018.txt}
WL_SHA=843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b
PY="$ENVP/bin/python3 -I"
NICE="nice -n ${NICE:-15}"
GEO=$DATA/studies/GSE155673/geo
GSM=GSM4712899
mkdir -p "$WORK/logs"
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
die() { echo "run.sh: $*" >&2; exit 1; }
heavy() { # retry heavy.sh while it is refused (exit 75), up to HEAVY_TRIES times
  local i rc
  for i in $(seq 1 "${HEAVY_TRIES:-48}"); do
    bash "$HERE/../gse152418/heavy.sh" "$LOCKS" REPRO-GSE155673 "${HEAVY_WAIT:-60}" "$@"
    rc=$?
    [ $rc -ne 75 ] && return $rc
    echo "heavy step refused (try $i), retrying $(date '+%H:%M:%S')"
  done
  return 75
}

if has stage; then
  bash "$HERE/stage.sh" "$DATA" "$HERE/runs.tsv" || die "staging did not finish (see the stage lines above)"
fi

if has inputs; then
  $PY "$HERE/prep.py" samples "$GEO/GSE155673_series_matrix.txt.gz" "$WORK/samples.tsv" || die samples
  $PY "$HERE/prep.py" deposits "$GEO" "$WORK/samples.tsv" "$WORK/deposited" || die deposits
fi

# The index REPRO-10X built from Ensembl 93 with 10x's GTF filter: its genes must equal the
# deposited features, id for id and in order, and the list must be REPRO-10X's.
if has index; then
  [ -s "$IDX/SA" ] && [ -s "$IDX/geneInfo.tab" ] || die "no STAR index at $IDX"
  awk 'NR > 1 {print $1}' "$IDX/geneInfo.tab" > "$WORK/index_genes.txt"
  gzip -cd "$GEO/GSE155673_features.tsv.gz" | awk -F'\t' '$3 == "Gene Expression" {print $1}' > "$WORK/deposit_genes.txt"
  cmp -s "$WORK/index_genes.txt" "$WORK/deposit_genes.txt" || die "index genes differ from the deposited features"
  [ "$(shasum -a 256 "$WL" | cut -d' ' -f1)" = "$WL_SHA" ] || die "whitelist sha256 differs from REPRO-10X's"
  echo "index $IDX: $(wc -l < "$WORK/index_genes.txt" | tr -d ' ') genes equal the deposit's, whitelist sha256 ok"
fi

if has align; then
  if [ ! -s "$WORK/solo/$GSM/Solo.out/Gene/filtered/matrix.mtx" ]; then
    est=${ALIGN_EST_GB:-$([ "${BAM:-1}" = 1 ] && echo 40 || echo 3)}
    bash "$HERE/disk_gate.sh" "$DATA" "$est" "STARsolo" || die "disk gate for STARsolo gave up"
  fi
  heavy $NICE bash "$HERE/solo.sh" "$DATA/studies/GSE155673/fastq" "$WORK" "$HERE/runs.tsv" "$THREADS" \
    "$LOCKS" "$IDX" "$WL" || die "align failed or refused"
fi

if has compare; then
  $NICE $PY "$HERE/compare.py" "$WORK" "$HERE/runs.tsv" "$WORK/samples.tsv" | tee "$WORK/logs/compare.log"
  # The full BAM goes once the library's counts pass the close class (R2 tally, Q4).
  if [ "${KEEP_BAM:-0}" != 1 ] && grep -q -x "$GSM" "$WORK/compare/pass_libraries.txt" 2>/dev/null; then
    rm -f "$WORK/solo/$GSM/Aligned.sortedByCoord.out.bam" "$WORK/solo/$GSM/Aligned.sortedByCoord.out.bam.bai"
    date '+%Y-%m-%d %H:%M:%S' > "$WORK/solo/$GSM/bam.deleted"
  fi
fi

if has claims; then
  export OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=4
  [ -s "$WORK/claims/stepA/results.tsv" ] || $NICE $PY "$HERE/claims.py" "$WORK" "$WORK/samples.tsv" \
    "$WORK/claims/stepA" | tee "$WORK/logs/claims_stepA.log"
  ours=$WORK/solo/$GSM/Solo.out/Gene/filtered
  if [ -s "$ours/matrix.mtx" ]; then
    $NICE $PY "$HERE/claims.py" "$WORK" "$WORK/samples.tsv" "$WORK/claims/substituted" "$ours" \
      | tee "$WORK/logs/claims_substituted.log"
  fi
fi
