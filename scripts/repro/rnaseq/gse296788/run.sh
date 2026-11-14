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
#   stages      ref index solo:<GSM> slice:<GSM> cells:<GSM> compare mtb claims prune
#               "all" (the default) runs ref, index, then solo, slice and cells for each
#               library, then compare and prune. compare runs mtb and claims at its end; mtb
#               (the not-host count and flag, from the kept slice and the raw matrix) and claims
#               (claims.tsv from the compare outputs) also run alone, both light, and read no full BAM
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

# Both counts are scored in the deposit's layout, where the 13 mitochondrial genes count 0 (every
# deposit holds 0 UMIs in them): exon-only (Cell Ranger 6.0's default) and exons plus introns
# (--include-introns), which the deposit turned out to be.
stage_compare() {
  stage_truth
  # shellcheck disable=SC2086
  $PY "$HERE/compare.py" --work "$WORK" --libs $LIBS --out "$WORK/compare" --no-mito-exons | tee "$WORK/logs/compare.log"
  # shellcheck disable=SC2086
  $PY "$HERE/compare.py" --work "$WORK" --libs $LIBS --out "$WORK/compare-genefull" --feature GeneFull_Ex50pAS \
    --no-mito-exons --no-background | tee "$WORK/logs/compare-genefull.log"
  stage_mtb
  stage_claims
}

# The Mtb strand and evidence counts and the GN not-host count and flag, from nonhost_and_mt.bam,
# STARsolo's raw Gene matrix and the top cells; no full BAM.
stage_mtb() {
  # shellcheck disable=SC2086
  $PY "$HERE/mtb.py" --work "$WORK" --libs $LIBS --out "$WORK/compare" \
    --mtb-gtf "$MTBREF"/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.gtf.gz | tee "$WORK/logs/mtb.log"
}

stage_claims() {
  $PY "$HERE/claims.py" --compare "$WORK/compare" --introns "$WORK/compare-genefull" --out "$WORK/compare/claims.tsv"
}

# A full BAM goes once the counts made from it pass their class (R2 tally, Q4); the slice stays.
stage_prune() {
  [ -s "$WORK/compare/pass_libs.txt" ] || return 0
  while read -r s; do rm -f "$WORK/solo/$s/Aligned.sortedByCoord.out.bam" "$WORK/solo/$s/Aligned.sortedByCoord.out.bam.bai"; done \
    < "$WORK/compare/pass_libs.txt"
}

# lge_refset (RS-REFSET, gate GR, not in "all"): lungfish-cli (LGE_CLI) builds the reference set in each
# layout under WORK/lge/${LGE_RUN:-RS-REFSET}/root, passed by --storage-root and never exported. Each set is
# checked against the study's reference and deleted, and its manifest and tables stay. The root's
# conda/envs/gffread is the RNA-seq pack's, or a link to LGE_PACK_ENV, an installed gffread environment.
LGE=$WORK/lge/${LGE_RUN:-RS-REFSET}
lge_build() { # <name> <option ...>: one timed build behind the heavy lock, the set left in LGE_SET
  local name=$1; shift
  mkdir -p "$LGE/root/conda/envs" "$LGE/logs"
  [ -x "$LGE/root/conda/envs/gffread/bin/gffread" ] || ln -sfn "${LGE_PACK_ENV:?no gffread in the root}" "$LGE/root/conda/envs/gffread"
  rm -rf "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset
  heavy /usr/bin/time -l -o "$LGE/logs/$name.time" $NICE "${LGE_CLI:?}" rnaseq reference-set --storage-root "$LGE/root" "$@" \
    > "$LGE/logs/$name.log" 2>&1 || { tail -5 "$LGE/logs/$name.log"; return 1; }
  LGE_SET=$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset)
  rm -rf "${LGE:?}/$name"; mkdir -p "$LGE/$name"
  cp "$LGE_SET/reference-set.json" "$LGE_SET"/derived/*.tsv "$LGE/$name/"
  log "$name $(basename "$LGE_SET") $(awk '/maximum resident/ {printf "peak %.1f GB", $1 / 2^30} /real/ {printf "%s s ", $1}' "$LGE/logs/$name.time")"
}
gr() { echo "GR gse296788 $*" | tee -a "$LGE/gr.txt"; } # <check> <pass|FAIL> <numbers>
verdict() { [ "$1" = "$2" ] && echo pass || echo FAIL; }
but_two() { awk 'NR > 2 { print two } { two = one; one = $0 }' "$1"; } # every line but the last two

stage_lge_refset() {
  local feats ids mtb=$LGE/mtb.gtf n layout d
  stage_truth; mkdir -p "$LGE"; : > "$LGE/gr.txt"
  feats="$(deposit_of GSM8976774)_features.tsv.gz"
  gzip -dc "$feats" | cut -f1 > "$LGE/deposit_features.txt"
  # the deposit's two Mtb features, tb001 and tb002, as ref.py writes them
  grep -E '^KK33948[78]\.1	' "$WORK/ref/genes.gtf" > "$mtb"
  for layout in lge deposit; do
    local opts=(--default cynomolgus/refseq-GCF_000364345.1
      --genome "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.fna.gz
      --annotation "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_genomic.gtf.gz
      --assembly-report "$REFSEQ"/GCF_000364345.1_Macaca_fascicularis_5.0_assembly_report.txt)
    if [ "$layout" = lge ]; then
      opts+=(--extra "bacterium,mtb,$MTBREF/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.fna.gz")
    else
      opts+=(--layout deposit --study GSE296788 --extra "bacterium,mtb,$MTBREF/GCA_000668235.1_Myco_tube_Erdman_V1_genomic.fna.gz,$mtb")
    fi
    lge_build "gse296788-$layout" "${opts[@]}" || { gr "$layout build FAIL"; continue; }
    d=$LGE/gse296788-$layout
    grep -v '^gene_id	' "$d/genes.tsv" | cut -f1 > "$d/ids.txt"
    n=$(wc -l < "$d/ids.txt" | tr -d ' ')
    gr "$layout features $(verdict "$n" 28847) $n of 28847"
    if [ "$layout" = deposit ]; then ids=$(cmp -s "$d/ids.txt" "$LGE/deposit_features.txt" && echo equal || echo differ)
    else ids=$(cmp -s <(but_two "$d/ids.txt") <(but_two "$LGE/deposit_features.txt") && echo equal || echo differ); fi
    gr "$layout order $(verdict "$ids" equal) $ids to the deposit features (LGE's layout without the two Mtb rows)"
    read -r added kept dropped < <($PY -c 'import json,sys; d=json.load(open(sys.argv[1])).get("derivation") or {}; print(*(len(d.get(k) or []) for k in ("exonsAdded","keptWithoutExon","droppedFeatures")))' "$d/reference-set.json")
    gr "$layout dropped $(verdict "$dropped" 24) $dropped empty gene_id features listed"
    local mito zero
    mito=$(awk -F'\t' '$4 == "NC_012670.1"' "$d/genes.tsv" | wc -l | tr -d ' ')
    zero=$(awk -F'\t' '$4 == "NC_012670.1" && $5 == 0' "$d/genes.tsv" | wc -l | tr -d ' ')
    if [ "$layout" = deposit ]; then
      gr "$layout mito $(verdict "$mito $zero $kept" "13 13 13") $mito on NC_012670.1, $zero at length 0, $kept kept without exon"
    else
      gr "$layout mito $(verdict "$mito $zero $added" "13 0 13") $mito on NC_012670.1, $zero at length 0, $added given CDS plus stop"
    fi
    rm -rf "$LGE_SET"
  done
}

for st in $STAGES; do
  case $st in
    lge_refset) stage_lge_refset ;;
    ref) stage_ref ;;
    index) stage_index ;;
    solo:*) stage_solo "${st#solo:}" ;;
    slice:*) stage_slice "${st#slice:}" ;;
    cells:*) stage_cells "${st#cells:}" ;;
    compare) stage_compare ;;
    mtb) stage_mtb ;;
    claims) stage_claims ;;
    prune) stage_prune ;;
    all)
      stage_ref; stage_index
      for s in $LIBS; do stage_solo "$s"; stage_slice "$s"; stage_cells "$s"; done
      stage_compare; stage_prune ;;
    *) echo "unknown stage $st"; exit 2 ;;
  esac
done
log "done: $STAGES"
