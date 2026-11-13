#!/usr/bin/env bash
# Reproduce 10x Genomics' public control matrices with STARsolo and simpleaf.
#
# Usage: run.sh DATA WORK ENV [STAGE ...]
#   DATA  folder holding tenx/<set>/ (10x's tars, matrices, molecule_info.h5)
#         and refs/ (Ensembl and GENCODE FASTA and GTF files)
#   WORK  folder for everything this script makes
#   ENV   conda environment with STAR, simpleaf, python (h5py, numpy, scipy, pandas)
#   STAGE one or more of: unpack refs whitelists index:<ref> solo:<set> pergenome:<set>
#         simpleaf-index simpleaf:<set> compare all  (default: all)
#
# Optional environment:
#   THREADS     threads for heavy steps (default 8)
#   NICE        nice level for heavy steps (default 15)
#   MAX_LOAD    when set, no heavy step starts while the 1-minute load average is at or above it
#   GENOME_RAM  bytes for STAR genomeGenerate (default 32000000000)
#   HEAVY_LOCK  a folder made with mkdir around each heavy step, removed after
#   LOCK_OWNER  text written to HEAVY_LOCK/owner
#   PAUSE_FILE  when this file exists, no heavy step starts
#   MIN_FREE    least percent of free memory (macOS memory_pressure) to start (default 35)
set -euo pipefail

if [ $# -lt 3 ]; then sed -n '2,20p' "$0"; exit 2; fi
DATA=$(cd "$1" && pwd); WORK=$2; ENV=$(cd "$3" && pwd); shift 3
STAGES=("${@:-all}")
HERE=$(cd "$(dirname "$0")" && pwd)
THREADS=${THREADS:-8}
NICE=${NICE:-15}
GENOME_RAM=${GENOME_RAM:-32000000000}
MIN_FREE=${MIN_FREE:-35}
export PATH="$ENV/bin:$PATH"
PY="$ENV/bin/python -I"
mkdir -p "$WORK"/{fastq,truth,ref,whitelist,index,solo,simpleaf,compare,logs}
WORK=$(cd "$WORK" && pwd)

# The three control sets of the brief, then a Cell Ranger 7.0.1 set (introns
# counted) that tests the second preset when its FASTQ tar is present.
SETS="pbmc_1k_v3 hgmm_1k_v3 sc5p_v2_hs_PBMC_1k"
CR7=SC3pv3_GEX_Human_PBMC
[ -s "$DATA/tenx/$CR7/${CR7}_fastqs.tar" ] && SETS="$SETS $CR7"
ref_of() { case $1 in
  SC3pv3_GEX_Human_PBMC) echo GRCh38-2020-A ;;
  pbmc_1k_v3) echo GRCh38-3.0.0 ;;
  hgmm_1k_v3) echo hg19-and-mm10-3.0.0 ;;
  sc5p_v2_hs_PBMC_1k) echo GRCh38-2020-A ;;
esac; }
log() { echo "[$(date '+%F %T')] $*"; }

# Wall time and peak memory of one command, into WORK/logs/<name>.time.
timed() {
  local name=$1; shift
  if [ "$(uname)" = Darwin ]; then nice -n "$NICE" /usr/bin/time -l -o "$WORK/logs/$name.time" "$@"
  else nice -n "$NICE" /usr/bin/time -v -o "$WORK/logs/$name.time" "$@"; fi
}

heavy_begin() {
  if [ -n "${PAUSE_FILE:-}" ] && [ -e "$PAUSE_FILE" ]; then log "pause file present, no heavy step"; exit 75; fi
  if [ "$(uname)" = Darwin ]; then
    local free; free=$(memory_pressure -Q | awk -F': ' '/free percentage/ {gsub("%","",$2); print $2}')
    if [ "${free:-0}" -lt "$MIN_FREE" ]; then log "memory free ${free}% under ${MIN_FREE}%"; exit 75; fi
  fi
  if [ -n "${MAX_LOAD:-}" ]; then
    local load; load=$(uptime | sed -E 's/.*load averages?: *([0-9.]+).*/\1/')
    if awk -v l="$load" -v m="$MAX_LOAD" 'BEGIN{exit !(l >= m)}'; then log "load $load at or above $MAX_LOAD"; exit 75; fi
  fi
  if [ -n "${HEAVY_LOCK:-}" ]; then
    mkdir "$HEAVY_LOCK" 2>/dev/null || { log "heavy lock held by $(cat "$HEAVY_LOCK/owner" 2>/dev/null)"; exit 75; }
    echo "${LOCK_OWNER:-tenx-controls} $(date '+%F %T') pid $$" > "$HEAVY_LOCK/owner"
    trap 'rm -rf "$HEAVY_LOCK"' EXIT
  fi
}
heavy_end() { if [ -n "${HEAVY_LOCK:-}" ]; then rm -rf "$HEAVY_LOCK"; trap - EXIT; fi; }

stage_unpack() {
  for s in $SETS; do
    if [ ! -d "$WORK/fastq/$s" ]; then
      mkdir -p "$WORK/fastq/$s"; tar -xf "$DATA/tenx/$s/${s}_fastqs.tar" -C "$WORK/fastq/$s"
    fi
    for k in filtered raw; do
      [ -d "$WORK/truth/$s/${k}_feature_bc_matrix" ] || { mkdir -p "$WORK/truth/$s"; tar -xzf "$DATA/tenx/$s/${s}_${k}_feature_bc_matrix.tar.gz" -C "$WORK/truth/$s"; }
    done
    log "unpacked $s"
  done
}

stage_refs() {
  local R=$DATA/refs
  # GRCh38-3.0.0: Ensembl 93 primary assembly, GTF through mkgtf's 17 biotypes.
  local o=$WORK/ref/GRCh38-3.0.0; mkdir -p "$o"
  [ -s "$o/genes.gtf" ] || $PY "$HERE/tenx_gtf.py" mkgtf-3.0.0 "$R/human/ensembl-93/Homo_sapiens.GRCh38.93.gtf.gz" "$o/genes.gtf"
  if [ ! -s "$o/genome.fa" ]; then
    gzip -dc "$R/human/ensembl-93/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" > "$o/genome.fa.tmp"
    mv "$o/genome.fa.tmp" "$o/genome.fa"
  fi
  # GRCh38-2020-A: Ensembl 98 primary assembly renamed to GENCODE names, GENCODE v32 GTF by the 2020-A rules.
  o=$WORK/ref/GRCh38-2020-A; mkdir -p "$o"
  [ -s "$o/genes.gtf" ] || $PY "$HERE/tenx_gtf.py" gencode-2020-A "$R/human/gencode-32/gencode.v32.primary_assembly.annotation.gtf.gz" "$o/genes.gtf"
  if [ ! -s "$o/genome.fa" ]; then
    gzip -dc "$R/human/ensembl-98/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" \
      | sed -E 's/^>([^[:space:]]+).*/>\1 \1/' \
      | sed -E 's/^>([0-9]+|[XY]) />chr\1 /' \
      | sed -E 's/^>MT />chrM /' > "$o/genome.fa.tmp"
    mv "$o/genome.fa.tmp" "$o/genome.fa"
  fi
  # hg19-and-mm10-3.0.0: Ensembl GRCh37 release 87 and GRCm38 release 93, GTFs unfiltered, names prefixed.
  o=$WORK/ref/hg19-and-mm10-3.0.0; mkdir -p "$o"
  if [ ! -s "$o/genes.gtf" ]; then
    rm -f "$o/genes.gtf.tmp"
    $PY "$HERE/tenx_prep.py" combine-gtf hg19 "$R/human/ensembl-grch37-87/Homo_sapiens.GRCh37.87.gtf.gz" "$o/genes.gtf.tmp"
    $PY "$HERE/tenx_prep.py" combine-gtf mm10 "$R/mouse/ensembl-93/Mus_musculus.GRCm38.93.gtf.gz" "$o/genes.gtf.tmp"
    mv "$o/genes.gtf.tmp" "$o/genes.gtf"
  fi
  if [ ! -s "$o/genome.fa" ]; then
    rm -f "$o/genome.fa.tmp"
    $PY "$HERE/tenx_prep.py" combine-fasta hg19 "$R/human/ensembl-grch37-87/Homo_sapiens.GRCh37.dna.primary_assembly.fa.gz" "$o/genome.fa.tmp"
    $PY "$HERE/tenx_prep.py" combine-fasta mm10 "$R/mouse/ensembl-93/Mus_musculus.GRCm38.dna.primary_assembly.fa.gz" "$o/genome.fa.tmp"
    mv "$o/genome.fa.tmp" "$o/genome.fa"
  fi
  for r in GRCh38-3.0.0 GRCh38-2020-A hg19-and-mm10-3.0.0; do
    ( cd "$WORK/ref/$r" && shasum -a 1 genome.fa genes.gtf > SHA1SUMS && cat SHA1SUMS )
  done
}

stage_whitelists() {
  [ -s "$WORK/whitelist/3M-february-2018.txt" ] || $PY "$HERE/tenx_prep.py" whitelist "$DATA/tenx/pbmc_1k_v3/pbmc_1k_v3_molecule_info.h5" "$WORK/whitelist/3M-february-2018.txt"
  [ -s "$WORK/whitelist/737K-august-2016.txt" ] || $PY "$HERE/tenx_prep.py" whitelist "$DATA/tenx/sc5p_v2_hs_PBMC_1k/sc5p_v2_hs_PBMC_1k_molecule_info.h5" "$WORK/whitelist/737K-august-2016.txt"
  # hgmm's list must equal pbmc's (both 3' v3, Cell Ranger 3.0.0).
  $PY "$HERE/tenx_prep.py" whitelist "$DATA/tenx/hgmm_1k_v3/hgmm_1k_v3_molecule_info.h5" "$WORK/whitelist/hgmm-check.txt"
  cmp "$WORK/whitelist/hgmm-check.txt" "$WORK/whitelist/3M-february-2018.txt" && rm "$WORK/whitelist/hgmm-check.txt"
  ( cd "$WORK/whitelist" && shasum -a 256 3M-february-2018.txt 737K-august-2016.txt | tee SHA256SUMS )
}

stage_index() {
  local r=$1 sparse=2
  # The combined human and mouse genome is twice the size; sparser suffix array keeps it under the memory cap.
  [ "$r" = hg19-and-mm10-3.0.0 ] && sparse=3
  local o=$WORK/index/$r
  [ -s "$o/SA" ] && { log "index $r present"; return; }
  rm -rf "$o"; mkdir -p "$o"
  heavy_begin
  log "STAR index $r sparse $sparse"
  timed "index-$r" STAR --runMode genomeGenerate --runThreadN "$THREADS" \
    --genomeDir "$o" --genomeFastaFiles "$WORK/ref/$r/genome.fa" \
    --sjdbGTFfile "$WORK/ref/$r/genes.gtf" --sjdbOverhang 100 \
    --genomeSAsparseD "$sparse" --limitGenomeGenerateRAM "$GENOME_RAM" \
    --outFileNamePrefix "$o/"
  heavy_end
}

# Chemistry and Cell Ranger version settings for each set.
solo_args() { case $1 in
  pbmc_1k_v3|hgmm_1k_v3)
    # 3' v3, Cell Ranger 3.0.0: STARsolo's "match CellRanger 3.x.x" options.
    echo "--soloCBwhitelist $WORK/whitelist/3M-february-2018.txt --soloUMIlen 12 --soloStrand Forward" ;;
  sc5p_v2_hs_PBMC_1k)
    # 5' v2 R2-only (SC5P-R2), Cell Ranger 5.0.0: the 3.x options plus "4.x.x and 5.x.x" clipping and score.
    echo "--soloCBwhitelist $WORK/whitelist/737K-august-2016.txt --soloUMIlen 10 --soloStrand Reverse --clipAdapterType CellRanger4 --outFilterScoreMin 30" ;;
  SC3pv3_GEX_Human_PBMC)
    # 3' v3, Cell Ranger 7.0.1 with introns: the 4.x and later options.
    echo "--soloCBwhitelist $WORK/whitelist/3M-february-2018.txt --soloUMIlen 12 --soloStrand Forward --clipAdapterType CellRanger4 --outFilterScoreMin 30" ;;
esac; }

# EmptyDrops_CR parameters. The first is expected cells: 1,000 where Cell
# Ranger's metrics record it, else STAR's default of 3,000.
ed_args() { case $1 in
  SC3pv3_GEX_Human_PBMC) echo "3000 0.99 10 45000 90000 500 0.01 20000 0.01 10000" ;;
  *) echo "1000 0.99 10 45000 90000 500 0.01 20000 0.01 10000" ;;
esac; }

reads_of() { # $1 set, $2 R1 or R2: comma list of that set's gene-expression lanes
  find "$WORK/fastq/$1" -name "*_${2}_001.fastq.gz" ! -name "*_5fb_*" | sort | paste -sd, -
}

stage_solo() {
  local s=$1 r; r=$(ref_of "$s")
  local o=$WORK/solo/$s
  [ -s "$o/Solo.out/Gene/filtered/matrix.mtx" ] && { log "solo $s present"; return; }
  rm -rf "$o"; mkdir -p "$o"
  heavy_begin
  log "STARsolo $s on $r"
  # shellcheck disable=SC2046
  timed "solo-$s" STAR --runThreadN "$THREADS" --genomeDir "$WORK/index/$r" \
    --readFilesIn "$(reads_of "$s" R2)" "$(reads_of "$s" R1)" --readFilesCommand gzip -cd \
    --soloType CB_UMI_Simple --soloCBstart 1 --soloCBlen 16 --soloUMIstart 17 \
    $(solo_args "$s") \
    --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
    --soloUMIdedup 1MM_CR \
    --soloCellFilter EmptyDrops_CR $(ed_args "$s") \
    --soloFeatures Gene GeneFull GeneFull_Ex50pAS \
    --outSAMtype None --outFileNamePrefix "$o/"
  heavy_end
  [ "$s" = hgmm_1k_v3 ] && stage_pergenome "$s"
  return 0
}

# Cell Ranger 3 calls cells for each genome of a mixed reference on that
# genome's counts. Do the same with STARsolo's EmptyDrops_CR on each half.
stage_pergenome() {
  local s=$1 o=$WORK/solo/$1/pergenome g
  rm -rf "$o"; mkdir -p "$o"
  $PY "$HERE/compare.py" split-genomes "$WORK/solo/$s/Solo.out/Gene/raw" "$o/raw" hg19 mm10
  for g in hg19 mm10; do
    mkdir -p "$o/STARsolo_Gene_$g"
    STAR --runMode soloCellFiltering "$o/raw_$g/" "$o/STARsolo_Gene_$g/" \
      --soloCellFilter EmptyDrops_CR 1000 0.99 10 45000 90000 500 0.01 20000 0.01 10000
  done
}

stage_simpleaf_index() {
  local r=GRCh38-3.0.0 o=$WORK/simpleaf/index-GRCh38-3.0.0
  [ -d "$o/index" ] && { log "simpleaf index present"; return; }
  export ALEVIN_FRY_HOME=$WORK/simpleaf/af_home; mkdir -p "$ALEVIN_FRY_HOME"
  simpleaf set-paths >/dev/null
  heavy_begin
  log "simpleaf index $r"
  timed simpleaf-index simpleaf index --output "$o" --fasta "$WORK/ref/$r/genome.fa" \
    --gtf "$WORK/ref/$r/genes.gtf" --rlen 91 --threads "$THREADS"
  heavy_end
}

stage_simpleaf() {
  local s=$1 o=$WORK/simpleaf/$1
  export ALEVIN_FRY_HOME=$WORK/simpleaf/af_home
  local idx=$WORK/simpleaf/index-GRCh38-3.0.0/index
  if [ -s "$o/af_quant/alevin/quants_mat.mtx" ]; then log "simpleaf $s present"; else
    rm -rf "$o"
    heavy_begin
    log "simpleaf quant $s"
    timed "simpleaf-$s" simpleaf quant --reads1 "$(reads_of "$s" R1)" --reads2 "$(reads_of "$s" R2)" \
      --index "$idx" --t2g-map "$idx/t2g_3col.tsv" --chemistry 10xv3 --resolution cr-like \
      --unfiltered-pl "$WORK/whitelist/3M-february-2018.txt" --threads "$THREADS" --output "$o"
    heavy_end
  fi
  [ -s "$o/filtered_SA_USA/matrix.mtx" ] && return 0
  rm -rf "$o/raw_SA" "$o/raw_SA_USA" "$o/filtered_SA" "$o/filtered_SA_USA"
  # Cell calls: the same EmptyDrops_CR as STARsolo, on simpleaf's spliced plus ambiguous counts.
  $PY "$HERE/compare.py" af-to-mex "$o/af_quant/alevin" "$o/raw_SA"
  for v in SA SA_USA; do
    mkdir -p "$o/filtered_$v"
    STAR --runMode soloCellFiltering "$o/raw_$v/" "$o/filtered_$v/" \
      --soloCellFilter EmptyDrops_CR 1000 0.99 10 45000 90000 500 0.01 20000 0.01 10000
  done
}

stage_compare() {
  for s in $SETS; do
    [ -d "$WORK/solo/$s/Solo.out" ] || continue
    $PY "$HERE/compare.py" compare "$s" "$WORK" "$DATA/tenx/$s" > "$WORK/compare/$s.txt"
    cat "$WORK/compare/$s.txt"
  done
}

for st in "${STAGES[@]}"; do
  case $st in
    unpack) stage_unpack ;;
    refs) stage_refs ;;
    whitelists) stage_whitelists ;;
    index:*) stage_index "${st#index:}" ;;
    solo:*) stage_solo "${st#solo:}" ;;
    pergenome:*) stage_pergenome "${st#pergenome:}" ;;
    simpleaf-index) stage_simpleaf_index ;;
    simpleaf:*) stage_simpleaf "${st#simpleaf:}" ;;
    compare) stage_compare ;;
    all)
      stage_unpack; stage_refs; stage_whitelists
      for s in $SETS; do stage_index "$(ref_of "$s")"; stage_solo "$s"; done
      stage_simpleaf_index; stage_simpleaf pbmc_1k_v3; stage_compare ;;
    *) echo "unknown stage $st"; exit 2 ;;
  esac
done
