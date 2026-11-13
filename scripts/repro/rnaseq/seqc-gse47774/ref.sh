#!/usr/bin/env bash
# Build the reference files of the SEQC lane from the Ensembl 100 genome and GTF and the
# Thermo Fisher ERCC92 set: a transcript FASTA made by gffread, the ERCC92 sequences
# appended, the genome appended as salmon decoys, a transcript-to-gene table, and a
# genome plus GTF with ERCC92 for the STAR cross-route.
#
# Usage: ref.sh <ensembl_dir> <ercc92_zip> <out_dir> <env_prefix>
#   ensembl_dir  holds Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz and Homo_sapiens.GRCh38.100.gtf.gz
#   ercc92_zip   ERCC92.zip from Thermo Fisher (ERCC92.fa and ERCC92.gtf)
set -euo pipefail
ENS=$1; ERCCZIP=$2; OUT=$3; ENVP=$4
BIN=$ENVP/bin
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
cd "$OUT"

[ -s genome.fa ] || { gzip -dc "$ENS/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" > genome.fa.tmp && mv genome.fa.tmp genome.fa; }
[ -s genome.fa.fai ] || "$BIN/samtools" faidx genome.fa
[ -s genes.gtf ] || { gzip -dc "$ENS/Homo_sapiens.GRCh38.100.gtf.gz" > genes.gtf.tmp && mv genes.gtf.tmp genes.gtf; }

mkdir -p ercc
[ -s ercc/ERCC92.fa ] || unzip -o -q "$ERCCZIP" ERCC92.fa ERCC92.gtf -d ercc

# Transcript sequences of every GTF transcript, named by transcript_id (no version).
[ -s transcripts.fa ] || { "$BIN/gffread" -w transcripts.fa.tmp -g genome.fa genes.gtf && mv transcripts.fa.tmp transcripts.fa; }

# salmon input: transcripts, then ERCC92, then the genome as decoys (decoys must come last).
if [ ! -s gentrome.fa ]; then
  grep '^>' genome.fa | sed 's/^>//; s/ .*//' > decoys.txt
  cat transcripts.fa ercc/ERCC92.fa genome.fa > gentrome.fa.tmp && mv gentrome.fa.tmp gentrome.fa
fi

# Transcript to gene table and gene table (ERCC rows map to themselves).
[ -s tx2gene.tsv ] || "$BIN/python3" -I "$HERE/tx2gene.py" genes.gtf ercc/ERCC92.fa tx2gene.tsv genes.tsv

# STAR cross-route: genome plus ERCC92 and the GTF plus ERCC92. ERCC92.gtf names each
# transcript by its GenBank accession (DQ459430) while ERCC92.fa names it ERCC-00002, so the
# transcript_id is set to the gene_id, so that STAR's transcriptome BAM matches the FASTA.
[ -s genome_ercc.fa ] || cat genome.fa ercc/ERCC92.fa > genome_ercc.fa
if [ ! -s genes_ercc.gtf ]; then
  { cat genes.gtf
    awk 'BEGIN{FS=OFS="\t"} {match($9, /gene_id "[^"]*"/); g=substr($9, RSTART+9, RLENGTH-10);
         $9="gene_id \"" g "\"; transcript_id \"" g "\"; gene_name \"" g "\"; gene_biotype \"ERCC\";"; print}' ercc/ERCC92.gtf
  } > genes_ercc.gtf.tmp && mv genes_ercc.gtf.tmp genes_ercc.gtf
fi

shasum -a 256 transcripts.fa ercc/ERCC92.fa tx2gene.tsv genes.tsv > ref.sha256
echo "transcripts: $(grep -c '^>' transcripts.fa)  ercc: $(grep -c '^>' ercc/ERCC92.fa)  decoys: $(wc -l < decoys.txt)"
