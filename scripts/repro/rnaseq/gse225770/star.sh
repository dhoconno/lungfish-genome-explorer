#!/usr/bin/env bash
# STAR for the nf-core/rnaseq 3.8.1 star_salmon route.
#   star.sh index <genome.fa> <gtf> <index_dir> <star_bin> <threads> <sparse_d> <samtools_bin> <log_dir>
#   star.sh align <index_dir> <gtf> <name> <r1> <r2> <out_dir> <star_bin> <threads>
#
# Index. nf-core module STAR_GENOMEGENERATE (modules/nf-core/modules/star/genomegenerate/main.nf):
#   STAR --runMode genomeGenerate --genomeDir star/ --genomeFastaFiles $fasta --sjdbGTFfile $gtf
#        --runThreadN $cpus --genomeSAindexNbases $NUM_BASES --limitGenomeGenerateRAM $memory
# with NUM_BASES = min(14, round(log2(genome size) / 2 - 1)), and no extra arguments in conf/modules.config.
# --genomeSAsparseD 2 is added on top (lane rule for macaque and human indexes), see the README.
#
# Alignment. nf-core module STAR_ALIGN (modules/nf-core/modules/star/align/main.nf) with the arguments
# of conf/modules.config for aligner star_salmon:
#   --quantMode TranscriptomeSAM --twopassMode Basic --outSAMtype BAM Unsorted --readFilesCommand zcat
#   --runRNGseed 0 --outFilterMultimapNmax 20 --alignSJDBoverhangMin 1 --outSAMattributes NH HI AS NM MD
#   --quantTranscriptomeBan Singleend
# and from the module itself --genomeDir --readFilesIn --runThreadN --outFileNamePrefix <name>.
#   --sjdbGTFfile <gtf> --outSAMattrRGline ID:<name> SM:<name>.
# Two differences, neither one changes an alignment. zcat on macOS looks for .Z files, so gunzip -c
# reads the gzip files. STAR 2.7.11b renamed --quantTranscriptomeBan Singleend to
# --quantTranscriptomeSAMoutput BanSingleEnd (its release notes say the default is unchanged).
set -euo pipefail
mode=$1; shift
case $mode in
index)
  FA=$1; GTF=$2; IDX=$3; STARBIN=$4; THREADS=$5; SPARSE=${6:-1}; SAMTOOLS=$7; LOGDIR=$8
  mkdir -p "$IDX" "$LOGDIR"
  [ -s "$FA.fai" ] || "$SAMTOOLS" faidx "$FA"
  NBASES=$(awk '{s+=$2} END{v=(log(s)/log(2))/2-1; if (v>14) printf "%.0f",14; else printf "%.0f",v}' "$FA.fai")
  echo "genomeSAindexNbases $NBASES genomeSAsparseD $SPARSE threads $THREADS"
  SP=""; [ "$SPARSE" != 1 ] && SP="--genomeSAsparseD $SPARSE"
  /usr/bin/time -l -o "$LOGDIR/star_index.time" "$STARBIN" --runMode genomeGenerate --genomeDir "$IDX" \
    --genomeFastaFiles "$FA" --sjdbGTFfile "$GTF" --runThreadN "$THREADS" \
    --genomeSAindexNbases "$NBASES" --limitGenomeGenerateRAM 32000000000 $SP \
    --outFileNamePrefix "$LOGDIR/star_index."
  ;;
align)
  IDX=$1; GTF=$2; NAME=$3; R1=$4; R2=$5; OUT=$6; STARBIN=$7; THREADS=$8
  mkdir -p "$OUT"; cd "$OUT"
  BAN="--quantTranscriptomeSAMoutput BanSingleEnd"
  "$STARBIN" --help 2>&1 | grep -q '^quantTranscriptomeBan' && BAN="--quantTranscriptomeBan Singleend"
  /usr/bin/time -l -o "$OUT/$NAME.star.time" "$STARBIN" --genomeDir "$IDX" --readFilesIn "$R1" "$R2" \
    --runThreadN "$THREADS" --outFileNamePrefix "$NAME." --outSAMtype BAM Unsorted \
    --sjdbGTFfile "$GTF" --outSAMattrRGline "ID:$NAME" "SM:$NAME" \
    --quantMode TranscriptomeSAM --twopassMode Basic --readFilesCommand gunzip -c --runRNGseed 0 \
    --outFilterMultimapNmax 20 --alignSJDBoverhangMin 1 --outSAMattributes NH HI AS NM MD $BAN
  ;;
*) echo "usage: star.sh index|align ..." >&2; exit 2 ;;
esac
