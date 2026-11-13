#!/usr/bin/env bash
# STARsolo on the libraries of runs.tsv, one library at a time, with REPRO-10X's Cell Ranger 3
# preset (3' v3 and v3.1: 16 nt barcode, 12 nt UMI, 3M-february-2018 list, forward strand,
# 1MM_multi_Nbase_pseudocounts, MultiGeneUMI_CR, 1MM_CR, EmptyDrops_CR). The paper ran
# Cell Ranger 3.0.2 (GEO record), whose default expected cells is 3,000.
# A library is skipped when its matrix and BAM index exist; the loop stops at a PAUSE file
# and a rerun goes on from the next library. The BAM is sorted with CB and UB tags so the
# reads on NC_045512.2 can be counted as one genome feature, and is indexed for slicing.
#
# Usage: solo.sh <data_root> <work_dir> <runs.tsv> <threads> <locks_dir|-> [GSM ...]
set -euo pipefail
DATA=$1; WORK=$2; RUNS=$3; THREADS=$4; LOCKS=$5; shift 5
FQ=$DATA/studies/GSE183579/fastq
IDX=${INDEX_DIR:-$WORK/index}
WL=$WORK/whitelist/3M-february-2018.txt
EXPECT=${EXPECT_CELLS:-3000}
libs=${*:-$(awk -F'\t' 'NR > 1 {print $2}' "$RUNS" | awk '!seen[$0]++')}
for gsm in $libs; do
  o=$WORK/solo/$gsm
  if [ -s "$o/Solo.out/Gene/filtered/matrix.mtx" ] && [ -s "$o/Aligned.sortedByCoord.out.bam.bai" ]; then
    echo "solo $gsm present"; continue
  fi
  if [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; then echo "PAUSE file, stopping before $gsm"; exit 75; fi
  runs=$(awk -F'\t' -v g="$gsm" '$2 == g {print $1}' "$RUNS")
  r1=$(for r in $runs; do printf '%s,' "$FQ/$gsm/${r}_R1_barcodeUMI.fastq.gz"; done | sed 's/,$//')
  r2=$(for r in $runs; do printf '%s,' "$FQ/$gsm/${r}_R2_cDNA.fastq.gz"; done | sed 's/,$//')
  rm -rf "$o"; mkdir -p "$o"
  echo "solo $gsm $(echo $runs | wc -w | tr -d ' ') runs start $(date '+%H:%M:%S')"
  /usr/bin/time -l STAR --runThreadN "$THREADS" --genomeDir "$IDX" \
    --readFilesIn "$r2" "$r1" --readFilesCommand gzip -cd \
    --soloType CB_UMI_Simple --soloCBstart 1 --soloCBlen 16 --soloUMIstart 17 --soloUMIlen 12 \
    --soloCBwhitelist "$WL" --soloStrand Forward \
    --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
    --soloUMIdedup 1MM_CR \
    --soloCellFilter EmptyDrops_CR "$EXPECT" 0.99 10 45000 90000 500 0.01 20000 0.01 10000 \
    --soloFeatures Gene GeneFull \
    --outSAMtype BAM SortedByCoordinate --outSAMattributes NH HI nM AS CR UR CB UB GX GN \
    --limitBAMsortRAM "${BAM_SORT_RAM:-8000000000}" --outBAMsortingThreadN 4 \
    --outFileNamePrefix "$o/" 2> "$o/time.txt"
  samtools index "$o/Aligned.sortedByCoord.out.bam"
  rm -rf "$o/_STARtmp"
  echo "solo $gsm done $(date '+%H:%M:%S') $(grep 'maximum resident' "$o/time.txt" | tr -s ' ')"
done
