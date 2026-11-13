#!/usr/bin/env bash
# GSE296788 (Pisu 2026), the five 10x 3' mRNA libraries of flow-sorted mCherry+ (Mtb-infected)
# cynomolgus lung cells: STARsolo with Cell Ranger 6.0's settings on Macaca_fascicularis_5.0
# (RefSeq Annotation Release 101) plus Mtb Erdman, scored against the deposited matrices.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE296788/{fastq,geo}, refs/cynomolgus/refseq-GCF_000364345.1,
#               refs/mtb/GCA_000668235.1 (stage_mtb.sh) and MANIFEST.tsv
#   work_dir    everything this script makes
#   env_prefix  conda environment with STAR 2.7.11b, samtools and python (scipy, pysam)
#   stages      ref index solo:<GSM> slice:<GSM> cells:<GSM> compare prune
#               "all" (the default) runs ref, index, then solo, slice and cells for each
#               library, then compare and prune
# Environment:
#   LOCKS       folder holding the shared heavy lock (mkdir LOCKS/heavy) and PAUSE; "-" runs heavy
#               steps at once (default "-")
#   HEAVY_WAIT  minutes a heavy step waits for the lock and the load gate (default 720)
#   THREADS     threads for heavy steps (default 8); light steps use at most 6
#   WHITELIST   10x 3M-february-2018 list (default DATA/work/tenx-controls/whitelist/3M-february-2018.txt);
#               its sha256 must equal the one REPRO-10X recorded
#   TEST_CONTIGS  space-separated contigs: build a small reference of only these (the light test)
#   TEST_READS    when set, each library uses only the first TEST_READS reads of its first run
set -euo pipefail
DATA=$(cd "$1" && pwd); WORK=$2; ENVP=$(cd "$3" && pwd); shift 3
STAGES=${*:-all}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE296788
REFSEQ=$DATA/refs/cynomolgus/refseq-GCF_000364345.1
MTBREF=$DATA/refs/mtb/GCA_000668235.1
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}; LIGHT=6
WHITELIST=${WHITELIST:-$DATA/work/tenx-controls/whitelist/3M-february-2018.txt}
WL_SHA=843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b
export PATH="$ENVP/bin:$PATH"
PY="nice -n 15 $ENVP/bin/python -I"
NICE="nice -n ${NICE:-15}"
# Smallest first (spots 156, 154, 173, 353 and 453 million), so results arrive early.
LIBS="GSM8976782 GSM8976774 GSM8976784 GSM8976786 GSM8976780"
mkdir -p "$WORK"/{ref,index,solo,compare,logs}
WORK=$(cd "$WORK" && pwd)
log() { echo "[$(date '+%F %T')] $*"; }
heavy() { bash "$HERE/heavy.sh" "$LOCKS" REPRO-GSE296788 "${HEAVY_WAIT:-720}" "$@"; }
# Wall time and peak memory of a heavy step, into WORK/logs/<name>.time.
TFLAG=-v; [ "$(uname)" = Darwin ] && TFLAG=-l
timed() { echo /usr/bin/time "$TFLAG" -o "$WORK/logs/$1.time"; }

# The deposit's file prefix and barcode count for each library (the deposits are forced counts).
deposit_of() { ls "$WORK/truth/$1"_*_barcodes.tsv.gz | head -1 | sed 's/_barcodes.tsv.gz$//'; }

stage_truth() {
  [ -n "$(ls "$WORK"/truth/*_matrix.mtx.gz 2>/dev/null)" ] && return 0
  mkdir -p "$WORK/truth"
  tar -xf "$STUDY/geo/GSE296788_RAW.tar" -C "$WORK/truth" --exclude='*ADT*'
}

stage_ref() {
  local o=$WORK/ref
  if [ ! -s "$o/genome.fa" ]; then
    if [ -n "${TEST_CONTIGS:-}" ]; then
      # shellcheck disable=SC2086
      { seqkit grep -p ${TEST_CONTIGS// / -p } "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.fna.gz
        seqkit grep -p ${TEST_CONTIGS// / -p } "$MTBREF"/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.fna.gz; } \
        | sed -E 's/^>([^[:space:]]+).*/>\1/' > "$o/genome.fa.tmp"
    else
      { gzip -dc "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.fna.gz
        gzip -dc "$MTBREF"/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.fna.gz; } \
        | sed -E 's/^>([^[:space:]]+).*/>\1/' > "$o/genome.fa.tmp"
    fi
    mv "$o/genome.fa.tmp" "$o/genome.fa"
  fi
  # shellcheck disable=SC2086
  $PY "$HERE/ref.py" gtf "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.gtf.gz \
    "$MTBREF"/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.fna.gz "$o/genes.gtf" ${TEST_CONTIGS:-}
  stage_truth
  [ -n "${TEST_CONTIGS:-}" ] || $PY "$HERE/ref.py" check "$o/genes.gtf" "$(deposit_of GSM8976774)_features.tsv.gz" | tee "$o/check.txt"
  $PY "$HERE/ref.py" mito "$o/genes.gtf" "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_assembly_report.txt "$o/mito_genes.tsv" | tee "$o/mito.txt"
  printf 'KK339487.1\t0\t3962231\nKK339488.1\t0\t463984\nNC_012670.1\t0\t16575\n' > "$o/nonhost_and_mt.bed"
  ( cd "$o" && shasum -a 256 genome.fa genes.gtf > SHA256SUMS && cat SHA256SUMS )
  [ "$(shasum -a 256 "$WHITELIST" | awk '{print $1}')" = "$WL_SHA" ] || { echo "whitelist sha256 differs"; exit 1; }
}

stage_index() {
  local o=$WORK/index sa=14 sparse=2
  grep -qs "finished successfully" "$o/Log.out" && { log "index present"; return 0; }
  [ -n "${TEST_CONTIGS:-}" ] && { sa=11; sparse=1; }
  rm -rf "$o" "$WORK/index_tmp"; mkdir -p "$o"
  log "STAR index sparse $sparse"
  heavy $(timed index) $NICE STAR --runMode genomeGenerate --runThreadN "$THREADS" --genomeDir "$o" \
    --genomeFastaFiles "$WORK/ref/genome.fa" --sjdbGTFfile "$WORK/ref/genes.gtf" --sjdbOverhang 100 \
    --genomeSAsparseD "$sparse" --genomeSAindexNbases "$sa" --limitGenomeGenerateRAM 32000000000 \
    --outFileNamePrefix "$o/" --outTmpDir "$WORK/index_tmp"
}

reads_of() { # $1 library, $2 R1_barcodeUMI or R2_cDNA: comma list of the library's runs
  if [ -n "${TEST_READS:-}" ]; then
    local f; f=$(ls "$STUDY/fastq/$1/"*_"$2".fastq.gz | head -1)
    mkdir -p "$WORK/testfq/$1"
    local t="$WORK/testfq/$1/$(basename "$f")"
    [ -s "$t" ] || { gzip -dc "$f" | head -n $((TEST_READS * 4)) | gzip -1 > "$t"; }
    echo "$t"
  else
    ls "$STUDY/fastq/$1/"*_"$2".fastq.gz | paste -sd, -
  fi
}

# Cell Ranger 6.0, 3' v3 (28 nt barcode read, G chip): STARsolo's options for Cell Ranger 4 and
# later, exon-only counting ("Gene"), EmptyDrops_CR with Cell Ranger's default 3,000 expected cells.
stage_solo() {
  local s=$1 o=$WORK/solo/$1
  if [ -s "$o/Log.final.out" ] && [ -s "$o/Solo.out/Gene/raw/matrix.mtx" ] \
     && { [ -s "$o/Aligned.sortedByCoord.out.bam" ] || [ -s "$o/nonhost_and_mt.bam" ]; }; then
    log "solo $s present"; return 0
  fi
  local r2 r1; r2=$(reads_of "$s" R2_cDNA); r1=$(reads_of "$s" R1_barcodeUMI)
  rm -rf "$o" "$WORK/tmp-$s"; mkdir -p "$o"
  log "STARsolo $s"
  heavy $(timed "solo-$s") $NICE STAR --runThreadN "$THREADS" --genomeDir "$WORK/index" \
    --readFilesIn "$r2" "$r1" --readFilesCommand gzip -cd \
    --soloType CB_UMI_Simple --soloCBstart 1 --soloCBlen 16 --soloUMIstart 17 --soloUMIlen 12 \
    --soloCBwhitelist "$WHITELIST" --soloStrand Forward \
    --clipAdapterType CellRanger4 --outFilterScoreMin 30 \
    --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
    --soloUMIdedup 1MM_CR --soloCellFilter EmptyDrops_CR \
    --soloFeatures Gene GeneFull_Ex50pAS \
    --outSAMtype BAM SortedByCoordinate --limitBAMsortRAM 8000000000 --outBAMsortingBinsN 100 \
    --outSAMattributes NH HI nM AS CR UR CB UB GX GN \
    --outFileNamePrefix "$o/" --outTmpDir "$WORK/tmp-$s"
}

# The BAM slice of the non-host contigs (both Mtb scaffolds) and the mitochondrion, kept for good.
stage_slice() {
  local s=$1 o=$WORK/solo/$1
  [ -s "$o/nonhost_and_mt.bam.bai" ] && return 0
  $NICE samtools index -@ "$LIGHT" "$o/Aligned.sortedByCoord.out.bam"
  $NICE samtools view -@ "$LIGHT" -b -o "$o/nonhost_and_mt.bam" \
    "$o/Aligned.sortedByCoord.out.bam" KK339487.1 KK339488.1 NC_012670.1
  samtools index "$o/nonhost_and_mt.bam"
}

# Cell Ranger's --force-cells keeps the top N barcodes by UMI count; every deposit here holds a
# round N (500 to 2,000), so the same call is made on our raw matrix.
stage_cells() {
  local s=$1 o=$WORK/solo/$1 n; stage_truth
  n=$(gzip -dc "$(deposit_of "$s")_barcodes.tsv.gz" | wc -l | tr -d ' ')
  rm -rf "$o/topcells"; mkdir -p "$o/topcells"
  $NICE STAR --runMode soloCellFiltering "$o/Solo.out/Gene/raw/" "$o/topcells/" --soloCellFilter TopCells "$n" \
    > "$WORK/logs/topcells-$s.log"
  log "top $n cells of $s"
}

stage_compare() {
  stage_truth
  $PY "$HERE/compare.py" --work "$WORK" --libs $LIBS --out "$WORK/compare" | tee "$WORK/logs/compare.log"
  $PY "$HERE/mtb.py" --work "$WORK" --libs $LIBS --out "$WORK/compare" \
    --mtb-gtf "$MTBREF"/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.gtf.gz | tee "$WORK/logs/mtb.log"
  $PY "$HERE/claims.py" --compare "$WORK/compare" --out "$WORK/compare/claims.tsv"
}

# A full BAM goes once the counts made from it pass their class (R2 tally, Q4); the slice stays.
stage_prune() {
  [ -s "$WORK/compare/pass_libs.txt" ] || return 0
  while read -r s; do rm -f "$WORK/solo/$s/Aligned.sortedByCoord.out.bam" "$WORK/solo/$s/Aligned.sortedByCoord.out.bam.bai"; done \
    < "$WORK/compare/pass_libs.txt"
}

for st in $STAGES; do
  case $st in
    ref) stage_ref ;;
    index) stage_index ;;
    solo:*) stage_solo "${st#solo:}" ;;
    slice:*) stage_slice "${st#slice:}" ;;
    cells:*) stage_cells "${st#cells:}" ;;
    compare) stage_compare ;;
    prune) stage_prune ;;
    all)
      stage_ref; stage_index
      for s in $LIBS; do stage_solo "$s"; stage_slice "$s"; stage_cells "$s"; done
      stage_compare; stage_prune ;;
    *) echo "unknown stage $st"; exit 2 ;;
  esac
done
log "done: $STAGES"
