#!/usr/bin/env bash
# Build the GSE183579 reference: Mmul_10 Ensembl 100 toplevel FASTA and its GTF with no
# biotype filter (the deposit's 35,432 ENSMMUG ids are every gene of that GTF), plus
# SARS-CoV-2 Wuhan-Hu-1 NC_045512.2 with its 11 NCBI genes named as deposited
# (gene_id gene-GU280_gp01 to gp11, gene_name ORF1ab to ORF10).
#
# The paper names the genomes (Methods, scRNA-seq data analysis) but not how the viral GFF3
# became a Cell Ranger GTF. Assumed here: one exon a gene over the GFF3 gene span, so the
# 3' UTR (29,675 to 29,903) and the 5' UTR belong to no gene, as in the deposit's ids.
#
# Usage: ref.sh <data_root> <out_dir>
set -euo pipefail
DATA=$1; OUT=$2
E=$DATA/refs/rhesus/ensembl-100
V=$DATA/refs/sars-cov-2/GCF_009858895.2/GCF_009858895.2_ASM985889v3
mkdir -p "$OUT"
if [ ! -s "$OUT/genome.fa" ]; then
  { gzip -cd "$E/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz"
    gzip -cd "${V}_genomic.fna.gz" | sed '1s/^>\([^ ]*\).*/>\1/'
  } > "$OUT/genome.fa.tmp"
  mv "$OUT/genome.fa.tmp" "$OUT/genome.fa"
fi
if [ ! -s "$OUT/genes.gtf" ]; then
  { gzip -cd "$E/Macaca_mulatta.Mmul_10.100.gtf.gz"
    gzip -cd "${V}_genomic.gff.gz" | awk -F'\t' -v OFS='\t' '$3 == "gene" {
      id = $9; sub(/.*ID=/, "", id); sub(/;.*/, "", id)
      nm = $9; sub(/.*;Name=/, "", nm); sub(/;.*/, "", nm)
      tx = id; sub(/^gene-/, "rna-", tx)
      a = "gene_id \"" id "\"; gene_name \"" nm "\"; gene_biotype \"protein_coding\";"
      print $1, "RefSeq", "gene", $4, $5, ".", $7, ".", a
      print $1, "RefSeq", "transcript", $4, $5, ".", $7, ".", a " transcript_id \"" tx "\";"
      print $1, "RefSeq", "exon", $4, $5, ".", $7, ".", a " transcript_id \"" tx "\"; exon_number \"1\";"
    }'
  } > "$OUT/genes.gtf.tmp"
  mv "$OUT/genes.gtf.tmp" "$OUT/genes.gtf"
fi
# gene_id, gene_name and contig, in GTF order, for the comparisons
awk -F'\t' '$3 == "gene" {
  id = $9; sub(/.*gene_id "/, "", id); sub(/".*/, "", id)
  nm = id; if ($9 ~ /gene_name "/) { nm = $9; sub(/.*gene_name "/, "", nm); sub(/".*/, "", nm) }
  print id "\t" nm "\t" $1 }' "$OUT/genes.gtf" > "$OUT/genes.tsv"
( cd "$OUT" && shasum -a 256 genome.fa genes.gtf genes.tsv > SHA256SUMS )
echo "genes $(wc -l < "$OUT/genes.tsv") virus $(grep -c '	NC_045512.2$' "$OUT/genes.tsv") mito $(grep -c '	MT$' "$OUT/genes.tsv")"
