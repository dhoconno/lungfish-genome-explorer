#!/usr/bin/env bash
# The cross-route on a few runs: STAR 2.7.11b on GRCh38 plus ERCC92 with the Ensembl 100 GTF,
# then three gene counts from the same alignment: STAR GeneCounts, featureCounts on the genome
# BAM, and salmon in alignment mode on STAR's transcriptome BAM (LGE's Linux default route).
# Usage:
#   star.sh index <ref_dir> <star_index> <env_prefix> [threads]          (heavy)
#   star.sh align <star_index> <fastq_dir> <run> <out_dir> <env_prefix> [threads]   (heavy)
#   star.sh count <ref_dir> <run> <out_dir> <env_prefix> [threads]       (light)
set -euo pipefail
MODE=$1; shift
case $MODE in
index)
  REF=$1; IDX=$2; ENVP=$3; T=${4:-8}
  if [ -e "$IDX/.complete" ]; then echo "index exists"; exit 0; fi
  rm -rf "$IDX.tmp"; mkdir -p "$IDX.tmp"
  "$ENVP/bin/STAR" --runMode genomeGenerate --runThreadN "$T" --genomeDir "$IDX.tmp" \
    --genomeFastaFiles "$REF/genome_ercc.fa" --sjdbGTFfile "$REF/genes_ercc.gtf" \
    --sjdbOverhang 100 --genomeSAsparseD 2 --limitGenomeGenerateRAM 32000000000 \
    --outFileNamePrefix "$IDX.tmp/"
  mv "$IDX.tmp" "$IDX"; touch "$IDX/.complete"; du -sh "$IDX" ;;
align)
  IDX=$1; FQ=$2; RUN=$3; OUT=$4; ENVP=$5; T=${6:-8}
  D=$OUT/$RUN; mkdir -p "$D"
  [ -s "$D/ReadsPerGene.out.tab" ] && { echo "$RUN aligned"; exit 0; }
  "$ENVP/bin/STAR" --runThreadN "$T" --genomeDir "$IDX" \
    --readFilesIn "$FQ/${RUN}_1.fastq.gz" "$FQ/${RUN}_2.fastq.gz" --readFilesCommand gzip -dc \
    --outSAMtype BAM Unsorted --quantMode TranscriptomeSAM GeneCounts \
    --outFileNamePrefix "$D/" ;;
count)
  REF=$1; RUN=$2; OUT=$3; ENVP=$4; T=${5:-6}
  D=$OUT/$RUN
  [ -s "$REF/transcripts_ercc.fa" ] || cat "$REF/transcripts.fa" "$REF/ercc/ERCC92.fa" > "$REF/transcripts_ercc.fa"
  # Unstranded (salmon detected IU on every run), pairs counted once, multimappers not counted.
  [ -s "$D/featureCounts.txt" ] || "$ENVP/bin/featureCounts" -T "$T" -p --countReadPairs -s 0 \
    -a "$REF/genes_ercc.gtf" -o "$D/featureCounts.txt" "$D/Aligned.out.bam" > "$D/featureCounts.log" 2>&1
  [ -s "$D/salmon_aln/quant.sf" ] || "$ENVP/bin/salmon" quant -t "$REF/transcripts_ercc.fa" -l A \
    -a "$D/Aligned.toTranscriptome.out.bam" -p "$T" -o "$D/salmon_aln" > "$D/salmon_aln.log" 2>&1
  echo "$RUN counted" ;;
*) echo "unknown mode $MODE"; exit 2 ;;
esac
