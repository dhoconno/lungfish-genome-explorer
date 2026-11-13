#!/usr/bin/env bash
# SEQC/MAQC-III (GSE47774), BGI samples A to D, libraries 1 to 5, lane L01: salmon with
# selective alignment against a decoy-aware Ensembl 100 index plus ERCC92, tximport to genes,
# limma A against B, and the paper's built-in truths scored on ours and on the deposited
# counts of the same 20 libraries. Optional STAR cross-route on a few runs.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root  holds studies/GSE47774/{fastq,geo,truth} and refs/human/ensembl-100
#   stages     ref index quant repeat gene de truth claims bias star (default: ref to claims, no repeat)
# Environment:
#   LOCKS      folder for the shared heavy lock (mkdir LOCKS/heavy around a heavy step);
#              "-" or unset runs heavy steps at once
#   THREADS    threads for heavy steps (default 8); QTHREADS for salmon quant (default 6)
#   STAR_RUNS  runs for the cross-route (default SRR896663 SRR896743, libraries A_1 and B_1)
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-ref index quant gene de truth claims}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE47774
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}; QTHREADS=${QTHREADS:-6}
STAR_RUNS=${STAR_RUNS:-SRR896663 SRR896743}
PY="$ENVP/bin/python3 -I"; RS="$ENVP/bin/Rscript --vanilla"
NICE="nice -n ${NICE:-15}"
mkdir -p "$WORK/logs"
heavy() { bash "$HERE/heavy.sh" "$LOCKS" REPRO-C1 "${HEAVY_WAIT:-240}" "$@"; }
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

has ref && $NICE bash "$HERE/ref.sh" "$DATA/refs/human/ensembl-100" "$STUDY/truth/ercc/ERCC92.zip" "$WORK/ref" "$ENVP"

has index && heavy $NICE bash "$HERE/index.sh" "$WORK/ref" "$WORK/salmon_index" "$ENVP" "$THREADS" 16

if has quant; then
  tail -n +2 "$HERE/samples.tsv" | cut -f1 | while read -r run; do
    # Ready when both mates have a ledger row whose source check is "yes" (ENA md5) or
    # "derived" (converted from an .sra whose md5 matched).
    nled=$(awk -F'\t' -v r="/fastq/${run}_" 'index($1, r) && ($6 == "yes" || $6 == "derived")' "$DATA/MANIFEST.tsv" | wc -l)
    if [ "$nled" -ge 2 ] && [ ! -e "$STUDY/fastq/${run}_1.fastq.gz.aria2" ] && [ ! -e "$STUDY/fastq/${run}_2.fastq.gz.aria2" ]; then
      $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant" "$ENVP" "$QTHREADS"
    else
      echo "$run not staged yet"
    fi
  done
fi

# salmon 2.6 and later quantify deterministically: the same run at another thread count must
# give the same quant.sf bytes. One run is enough to show it.
if has repeat; then
  mkdir -p "$WORK/claims"
  run=${REPEAT_RUN:-SRR896679}
  $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant_repeat" "$ENVP" 3
  if cmp -s "$WORK/quant/$run/quant.sf" "$WORK/quant_repeat/$run/quant.sf"; then
    echo "repeat $run at 3 threads: quant.sf identical" | tee "$WORK/claims/repeat.txt"
  else
    echo "repeat $run at 3 threads: quant.sf differs" | tee "$WORK/claims/repeat.txt"
  fi
fi

has gene && $NICE $RS "$HERE/gene.R" "$WORK/quant" "$HERE/samples.tsv" "$WORK/ref/tx2gene.tsv" "$WORK/gene"

if has de; then
  mkdir -p "$WORK/deposited"
  $PY "$HERE/deposited.py" "$STUDY/geo/GSE47774_SEQC_ILM_BGI.txt.gz" "$STUDY/truth/ucsc-hg19-refgene/refGene.txt.gz" \
    "$HERE/samples.tsv" "$WORK/deposited/deposited"
  $NICE $RS "$HERE/de.R" "$WORK/deposited/deposited_counts.tsv" "$WORK/deposited/de_AB_deposited.tsv"
  $NICE $RS "$HERE/de.R" "$WORK/gene/gene_counts.tsv" "$WORK/gene/de_AB_ours.tsv"
fi

if has truth; then
  mkdir -p "$WORK/truth"
  $PY "$HERE/taqman.py" "$STUDY/truth/gpl4097/GPL4097_family.soft.gz" "$STUDY/truth/gpl4097/GPL4097.annot.gz" "$WORK/truth/taqman.tsv"
fi

if has claims; then
  $NICE $PY "$HERE/compare.py" --gene-dir "$WORK/gene" --genes "$WORK/ref/genes.tsv" \
    --deposited "$WORK/deposited/deposited_counts.tsv" --de-ours "$WORK/gene/de_AB_ours.tsv" \
    --de-deposited "$WORK/deposited/de_AB_deposited.tsv" --taqman "$WORK/truth/taqman.tsv" \
    --ercc-conc "$STUDY/truth/ercc/cms_095046.txt" --out "$WORK/claims" > "$WORK/logs/compare.log"
  $PY "$HERE/claims.py" "$WORK/claims/metrics.json" "$WORK/claims/claims.tsv"
fi

# The same quant with salmon's sequence and GC bias models, scored the same way, to see which
# truths the flags move.
if has bias; then
  tail -n +2 "$HERE/samples.tsv" | cut -f1 | while read -r run; do
    SALMON_EXTRA="--seqBias --gcBias" $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant_gcbias" "$ENVP" "$QTHREADS"
  done
  $NICE $RS "$HERE/gene.R" "$WORK/quant_gcbias" "$HERE/samples.tsv" "$WORK/ref/tx2gene.tsv" "$WORK/gene_gcbias"
  $NICE $RS "$HERE/de.R" "$WORK/gene_gcbias/gene_counts.tsv" "$WORK/gene_gcbias/de_AB_ours.tsv"
  mkdir -p "$WORK/claims_gcbias"
  [ -s "$WORK/claims/repeat.txt" ] && cp "$WORK/claims/repeat.txt" "$WORK/claims_gcbias/"
  $NICE $PY "$HERE/compare.py" --gene-dir "$WORK/gene_gcbias" --genes "$WORK/ref/genes.tsv" \
    --deposited "$WORK/deposited/deposited_counts.tsv" --de-ours "$WORK/gene_gcbias/de_AB_ours.tsv" \
    --de-deposited "$WORK/deposited/de_AB_deposited.tsv" --taqman "$WORK/truth/taqman.tsv" \
    --ercc-conc "$STUDY/truth/ercc/cms_095046.txt" --out "$WORK/claims_gcbias" > "$WORK/logs/compare_gcbias.log"
  $PY "$HERE/claims.py" "$WORK/claims_gcbias/metrics.json" "$WORK/claims_gcbias/claims.tsv"
fi

if has star; then
  heavy $NICE bash "$HERE/star.sh" index "$WORK/ref" "$WORK/star_index" "$ENVP" "$THREADS"
  for run in $STAR_RUNS; do
    heavy $NICE bash "$HERE/star.sh" align "$WORK/star_index" "$STUDY/fastq" "$run" "$WORK/star" "$ENVP" "$THREADS"
    $NICE bash "$HERE/star.sh" count "$WORK/ref" "$run" "$WORK/star" "$ENVP" "$QTHREADS"
  done
  $NICE $PY "$HERE/routes.py" "$WORK" "$HERE/samples.tsv" $STAR_RUNS > "$WORK/logs/routes.log"
fi
