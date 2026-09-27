#!/usr/bin/env bash
# Slice the GIAB Ashkenazi parents, HG003 (father) and HG004 (mother), over
# the same GRCh38 chr20 10.0 to 10.5 Mb region as the hg002-chr20 fixture,
# with the same source (NIST/GIAB Illumina 2x250bp novoalign BAMs), the same
# downsampling (samtools view -s 42.65) and the same coordinate shift for the
# benchmark VCFs. HG002 (the son) is not rebuilt here: it comes from
# docs/user-manual/fixtures/hg002-chr20 (pinned manual-media repo).
#
# Needs samtools, bcftools, and htslib (bgzip, tabix) from the managed
# lungfish-tools environment; the paths below are the managed installs.
# Override CACHE to keep the remote index caches and intermediate BAMs
# somewhere other than ./cache.
set -euo pipefail
cd "$(dirname "$0")"
ENV="${LUNGFISH_CONDA_ROOT:-$HOME/.lungfish/conda}/envs"
SAMTOOLS="$ENV/samtools/bin/samtools"; BCFTOOLS="$ENV/bcftools/bin/bcftools"
BGZIP="$ENV/htslib/bin/bgzip"; TABIX="$ENV/htslib/bin/tabix"
REGION="chr20:10000000-10500000"; OFFSET=9999999
CACHE="${CACHE:-cache}"
GIAB="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab"
# Same kept fraction and seed as hg002-chr20/fetch.sh so the three samples
# sit at comparable depth (about 40x to 45x each after downsampling).
DOWNSAMPLE_FRACTION="0.65"
mkdir -p "$CACHE"

slice_sample() {
  local sample="$1" folder="$2"
  local bam="$GIAB/data/AshkenazimTrio/$folder/NIST_Illumina_2x250bps/novoalign_bams/$sample.GRCh38.2x250.bam"
  local vcf="$GIAB/release/AshkenazimTrio/$folder/NISTv4.2.1/GRCh38/${sample}_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
  # Reads: remote region fetch (htslib range GETs, the whole-genome BAM is
  # never downloaded), downsample, name-sort, paired FASTQ.
  if [ ! -f "$CACHE/$sample.slice.bam" ]; then
    ( cd "$CACHE" && "$SAMTOOLS" view -b -h "$bam" "$REGION" > "$sample.slice.bam.part" && mv "$sample.slice.bam.part" "$sample.slice.bam" )
  fi
  "$SAMTOOLS" view -b -s "42${DOWNSAMPLE_FRACTION#0}" -o "$CACHE/$sample.slice.ds.bam" "$CACHE/$sample.slice.bam"
  "$SAMTOOLS" sort -n -o "$CACHE/$sample.slice.nsort.bam" "$CACHE/$sample.slice.ds.bam"
  "$SAMTOOLS" fastq -1 "$sample.chr20.10.0-10.5Mb_R1.fastq.gz" -2 "$sample.chr20.10.0-10.5Mb_R2.fastq.gz" \
    -0 /dev/null -s /dev/null -n "$CACHE/$sample.slice.nsort.bam"
  # Benchmark calls, shifted into fixture coordinates (1-based, 1 to 500,001).
  ( cd "$CACHE" && "$BCFTOOLS" view -r "$REGION" "$vcf" -Ou ) \
    | "$BCFTOOLS" annotate --rename-chrs <(echo "chr20 chr20_10.0-10.5Mb") -Ov \
    | awk -v o="$OFFSET" 'BEGIN{OFS="\t"} /^#/ {print; next} {$2=$2-o; print}' \
    | "$BGZIP" -c > "$sample.chr20.10.0-10.5Mb.benchmark.vcf.gz"
  "$TABIX" -f -p vcf "$sample.chr20.10.0-10.5Mb.benchmark.vcf.gz"
}

slice_sample HG003 HG003_NA24149_father
slice_sample HG004 HG004_NA24143_mother
du -sh *.fastq.gz *.vcf.gz
