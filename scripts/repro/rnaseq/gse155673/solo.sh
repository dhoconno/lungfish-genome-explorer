#!/usr/bin/env bash
# STARsolo on one library (cov_10, GSM4712899): its 8 runs in one call, with REPRO-10X's
# Cell Ranger 3 preset for 3' v3 (16 nt barcode, 12 nt UMI, 3M-february-2018 list, forward
# strand, 1MM_multi_Nbase_pseudocounts, MultiGeneUMI_CR, 1MM_CR, EmptyDrops_CR). GEO names
# "Cellranger 3.1", whose default expected cells is 3,000. The sorted BAM carries CR, UR, CB
# and UB tags for diagnosis and is deleted once the library passes its close class.
# The library is skipped when its matrix exists (and its BAM index, when a BAM is asked for).
#
# Usage: solo.sh <fastq_dir> <work_dir> <runs.tsv> <threads> <locks_dir|-> <index_dir> <whitelist>
# Environment: EXPECT_CELLS (3000), BAM (1 writes the sorted BAM, 0 none), BAM_SORT_RAM
set -euo pipefail
FQ=$1; WORK=$2; RUNS=$3; THREADS=$4; LOCKS=$5; IDX=$6; WL=$7
EXPECT=${EXPECT_CELLS:-3000}
for gsm in $(awk -F'\t' 'NR > 1 {print $2}' "$RUNS" | awk '!seen[$0]++'); do
  o=$WORK/solo/$gsm
  if [ -s "$o/Solo.out/Gene/filtered/matrix.mtx" ] && { [ "${BAM:-1}" = 0 ] || [ -s "$o/Aligned.sortedByCoord.out.bam.bai" ] || [ -e "$o/bam.deleted" ]; }; then
    echo "solo $gsm present"; continue
  fi
  if [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; then echo "PAUSE file, stopping before $gsm"; exit 75; fi
  runs=$(awk -F'\t' -v g="$gsm" 'NR > 1 && $2 == g {print $1}' "$RUNS")
  r1=$(for r in $runs; do printf '%s,' "$FQ/$gsm/${r}_R1_barcodeUMI.fastq.gz"; done | sed 's/,$//')
  r2=$(for r in $runs; do printf '%s,' "$FQ/$gsm/${r}_R2_cDNA.fastq.gz"; done | sed 's/,$//')
  for f in $(echo "$r1,$r2" | tr ',' ' '); do [ -s "$f" ] || { echo "solo: missing $f"; exit 1; }; done
  if [ "${BAM:-1}" = 1 ]; then
    bam=(--outSAMtype BAM SortedByCoordinate --outSAMattributes NH HI nM AS CR UR CB UB GX GN
         --limitBAMsortRAM "${BAM_SORT_RAM:-8000000000}" --outBAMsortingThreadN 4)
  else
    bam=(--outSAMtype None)
  fi
  rm -rf "$o"; mkdir -p "$o"
  echo "solo $gsm $(echo $runs | wc -w | tr -d ' ') runs start $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -l STAR --runThreadN "$THREADS" --genomeDir "$IDX" \
    --readFilesIn "$r2" "$r1" --readFilesCommand gzip -cd \
    --soloType CB_UMI_Simple --soloCBstart 1 --soloCBlen 16 --soloUMIstart 17 --soloUMIlen 12 \
    --soloCBwhitelist "$WL" --soloStrand Forward \
    --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
    --soloUMIdedup 1MM_CR \
    --soloCellFilter EmptyDrops_CR "$EXPECT" 0.99 10 45000 90000 500 0.01 20000 0.01 10000 \
    --soloFeatures Gene GeneFull \
    "${bam[@]}" --outFileNamePrefix "$o/" 2> "$o/time.txt"
  [ "${BAM:-1}" = 1 ] && samtools index "$o/Aligned.sortedByCoord.out.bam"
  rm -rf "$o/_STARtmp"
  echo "solo $gsm done $(date '+%Y-%m-%d %H:%M:%S') $(grep 'maximum resident' "$o/time.txt" | tr -s ' ')"
done
