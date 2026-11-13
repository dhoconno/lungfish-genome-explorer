#!/usr/bin/env bash
# STAR 2.7.3a, the version the paper names, at its default parameters except the ones below.
# The index holds the Ensembl GTF (junctions and the gene model for --quantMode GeneCounts)
# and --sjdbOverhang 100, which is STAR's default and read length minus one for 101-base reads.
# No --genomeSAsparseD, so the suffix array is the full one. Every other option is a default.
# Usage:
#   star.sh index <fasta> <gtf> <index_dir> <star_env> [threads] [sjdb_overhang]     (heavy)
#   star.sh align <index_dir> <out_dir> <star_env> <threads> <reads_1> [<reads_2>]   (heavy)
# STAR_INDEX_EXTRA adds options to the index build, for a toy genome in a script test only.
# For align, give one FASTQ (single-end) or two (paired), each file or a comma list of files.
set -euo pipefail
MODE=$1; shift
case $MODE in
index)
  FA=$1; GTF=$2; IDX=$3; ENVP=$4; T=${5:-8}; OVH=${6:-100}
  if [ -e "$IDX/.complete" ]; then echo "index exists"; exit 0; fi
  rm -rf "$IDX.tmp"; mkdir -p "$IDX.tmp"
  /usr/bin/time -l -o "$IDX.tmp/time.txt" "$ENVP/bin/STAR" --runMode genomeGenerate --runThreadN "$T" \
    --genomeDir "$IDX.tmp" --genomeFastaFiles "$FA" --sjdbGTFfile "$GTF" --sjdbOverhang "$OVH" \
    --limitGenomeGenerateRAM 32000000000 --outFileNamePrefix "$IDX.tmp/" ${STAR_INDEX_EXTRA:-}
  rm -rf "$IDX"
  mv "$IDX.tmp" "$IDX"; touch "$IDX/.complete"; du -sh "$IDX" ;;
align)
  IDX=$1; D=$2; ENVP=$3; T=$4; shift 4
  mkdir -p "$D"
  if [ -s "$D/ReadsPerGene.out.tab" ] && [ -s "$D/Log.final.out" ]; then echo "$D aligned"; exit 0; fi
  rm -rf "$D/_STARtmp"   # left by an interrupted run, and STAR refuses to start beside it
  /usr/bin/time -l -o "$D/time.txt" "$ENVP/bin/STAR" --runThreadN "$T" --genomeDir "$IDX" \
    --readFilesIn "$@" --readFilesCommand gunzip -c --outSAMtype BAM Unsorted --quantMode GeneCounts \
    --outFileNamePrefix "$D/" ;;
*) echo "unknown mode $MODE"; exit 2 ;;
esac
