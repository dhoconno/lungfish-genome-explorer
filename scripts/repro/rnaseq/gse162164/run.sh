#!/usr/bin/env bash
# GSE162164 (C5), human whole blood, TB in advanced HIV, India cohort, 25 runs PE150 (trimmed
# before deposit). salmon on two indexes, gene and symbol tables against the deposited 14,440 x 25
# matrix, and the paper's DE and two-gene signature on the deposit and on ours.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE162164/{fastq,geo,paper}, refs/human/ensembl-100 and MANIFEST.tsv
#   work_dir    derived files; work_dir/../seqc-gse47774 holds REPRO-C1's decoy-aware index
#   env_prefix  the main environment; sva comes from env-r-sva beside it (R_ENV)
#   stages      samples ref supp deposit index quant_paper quant_decoy compare de, or chain
#               (default: chain, which runs them all in the order the shared machine needs)
# Environment:
#   LOCKS       folder of the shared heavy lock; "-" or unset runs the index build at once
#   DECOY_DIR   REPRO-C1's work folder (default work_dir/../seqc-gse47774)
#   R_ENV       the R environment with sva (default env-r-sva beside env_prefix)
#   THREADS     threads for salmon (default 6); HEAVY_WAIT minutes a lock attempt (default 120)
#   LATE_WAIT   minutes to wait for runs still downloading (default 360)
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-chain}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE162164
DECOY_DIR=${DECOY_DIR:-$(dirname "$WORK")/seqc-gse47774}
R_ENV=${R_ENV:-$(dirname "$ENVP")/env-r-sva}
LOCKS=${LOCKS:--}; THREADS=${THREADS:-6}
PY="$ENVP/bin/python3 -I"; RS="$R_ENV/bin/Rscript --vanilla"
NICE="nice -n ${NICE:-15}"
SHEET=$HERE/samples.tsv
mkdir -p "$WORK/logs"
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

samples() { $PY "$HERE/samples.py" "$STUDY" "$WORK/samples.tsv" && cmp "$WORK/samples.tsv" "$SHEET"; }
ref() { $NICE bash "$HERE/ref.sh" "$DATA/refs/human/ensembl-100" "$WORK/ref" "$ENVP"; }
supp() { # Supplementary Table 2 (the DEG lists) from Europe PMC's supplementary bundle
  local d=$STUDY/paper/supp
  mkdir -p "$d" "$WORK/supp"
  [ -s "$d/PMC7937880_supp.zip" ] || curl -fsS --retry 3 -o "$d/PMC7937880_supp.zip" \
    "https://www.ebi.ac.uk/europepmc/webservices/rest/PMC7937880/supplementaryFiles"
  mkdir -p "$d/x"; unzip -o -q "$d/PMC7937880_supp.zip" 'Table_2*' -d "$d/x"
  $PY "$HERE/xlsx2tsv.py" "$d/x/Table_2.XLSX" "$WORK/supp/table2"
}
deposit() {
  mkdir -p "$WORK/deposited"
  gunzip -c "$STUDY/geo/GSE162164_counts.txt.gz" | awk 'NR == 1 {print "gene\t" $0; next} {print}' \
    > "$WORK/deposited/counts.tsv"
}
index() { # heavy: reruns heavy.sh while it is refused (exit 75), until the index exists
  until [ -e "$WORK/salmon_index_paper/.complete" ]; do
    rc=0
    bash "$HERE/heavy.sh" "$LOCKS" REPRO-C5 "${HEAVY_WAIT:-120}" bash -c \
      "touch '$WORK/quant_decoy.STOP'; $NICE bash '$HERE/index.sh' '$WORK/ref/paper_tx.fa' \
       '$WORK/salmon_index_paper' '$ENVP' $THREADS 16" || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 75 ] || { log "index failed rc $rc"; return "$rc"; }
  done
}
quant_paper() { $NICE bash "$HERE/quant.sh" "$DATA" "$SHEET" "$WORK/salmon_index_paper" "$WORK/quant_paper" "$ENVP" "$THREADS"; }
quant_decoy() { STOP_FILE=${STOP_FILE:-} $NICE bash "$HERE/quant.sh" "$DATA" "$SHEET" "$DECOY_DIR/salmon_index" "$WORK/quant_decoy" "$ENVP" "$THREADS"; }
compare() {
  [ -d "$WORK/quant_paper" ] && $NICE $PY "$HERE/compare.py" --quant "$WORK/quant_paper" \
    --tx2gene "$WORK/ref/tx2gene_paper.tsv" --fasta-order "$WORK/ref/paper_tx.fa" --samples "$SHEET" \
    --deposit "$STUDY/geo/GSE162164_counts.txt.gz" --out "$WORK/compare_paper"
  [ -d "$WORK/quant_decoy" ] && $NICE $PY "$HERE/compare.py" --quant "$WORK/quant_decoy" \
    --tx2gene "$DECOY_DIR/ref/tx2gene.tsv" --fasta-order "$DECOY_DIR/ref/transcripts_ercc.fa" \
    --samples "$SHEET" --deposit "$STUDY/geo/GSE162164_counts.txt.gz" --out "$WORK/compare_decoy"
  return 0
}
de() { # step A on the deposit, step B on ours (gene sums, the tximport default), same script
  local t2=$WORK/supp/table2.1.India_DEGS.tsv
  $NICE $RS "$HERE/de.R" "$WORK/deposited/counts.tsv" "$SHEET" "$t2" "$WORK/de_deposit" 1
  for arm in paper decoy; do
    f=$WORK/compare_$arm/ours_sum_by_symbol.tsv
    [ -s "$f" ] && $NICE $RS "$HERE/de.R" "$f" "$SHEET" "$t2" "$WORK/de_${arm}_sum" "$([ $arm = paper ] && echo 1 || echo 0)"
  done
  return 0
}
nquant() { ls "$WORK/$1"/*/quant.sf 2>/dev/null | wc -l | tr -d ' '; }

if has chain; then
  log "chain start"; samples; ref; supp; deposit
  rm -f "$WORK/quant_decoy.STOP"
  # The decoy-aware arm needs no lock, so it runs while the paper index waits for the heavy lock.
  # The index step touches quant_decoy.STOP once it holds the lock, and the loop ends between runs.
  STOP_FILE=$WORK/quant_decoy.STOP quant_decoy > "$WORK/logs/quant_decoy_early.log" 2>&1 &
  early=$!
  index; log "index ready"
  wait "$early" || true; rm -f "$WORK/quant_decoy.STOP"; log "early decoy loop ended"
  quant_paper; log "paper quant pass done ($(nquant quant_paper) runs)"
  quant_decoy; log "decoy quant pass done ($(nquant quant_decoy) runs)"
  compare; de; log "first analysis done"
  # Runs the bulk downloader is still fetching get quantified when their ledger rows appear.
  deadline=$(( $(date +%s) + ${LATE_WAIT:-360} * 60 ))
  while [ "$(nquant quant_paper)" -lt 25 ] || [ "$(nquant quant_decoy)" -lt 25 ]; do
    [ "$(date +%s)" -ge "$deadline" ] && { log "late runs still missing at the deadline"; break; }
    sleep 600
    before=$(( $(nquant quant_paper) + $(nquant quant_decoy) ))
    quant_paper; quant_decoy
    if [ $(( $(nquant quant_paper) + $(nquant quant_decoy) )) -gt "$before" ]; then
      compare; de; log "analysis redone ($(nquant quant_paper) paper, $(nquant quant_decoy) decoy runs)"
    fi
  done
  log "chain done"; touch "$WORK/CHAIN_DONE"
  exit 0
fi
for s in samples ref supp deposit index quant_paper quant_decoy compare de; do
  if has $s; then log "stage $s"; $s; fi
done
