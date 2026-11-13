#!/usr/bin/env bash
# Unpack one Ensembl release (genome FASTA and GTF) into the work folder, after checking each
# gzip file against the sha256 file that sits beside it, and write the gene table STAR counts.
# Usage: ref.sh <ref_src_dir> <fasta_gz_name> <gtf_gz_name> <out_dir>
# Writes <out_dir>/genome.fa, genes.gtf, genes.tsv (one gene_id a line, order of first exon
# line, the genes STAR reports in ReadsPerGene.out.tab) and SOURCES.tsv.
set -euo pipefail
SRC=$1; FA=$2; GTF=$3; OUT=$4
mkdir -p "$OUT"
for f in "$FA" "$GTF"; do
  want=$(awk '{print $1}' "$SRC/$f.sha256")
  have=$(shasum -a 256 "$SRC/$f" | awk '{print $1}')
  [ "$want" = "$have" ] || { echo "sha256 mismatch for $f"; exit 1; }
done
if [ ! -s "$OUT/genome.fa" ]; then
  gunzip -c "$SRC/$FA" > "$OUT/genome.fa.tmp"; mv "$OUT/genome.fa.tmp" "$OUT/genome.fa"
fi
if [ ! -s "$OUT/genes.gtf" ]; then
  gunzip -c "$SRC/$GTF" > "$OUT/genes.gtf.tmp"; mv "$OUT/genes.gtf.tmp" "$OUT/genes.gtf"
fi
if [ ! -s "$OUT/genes.tsv" ]; then
  awk -F'\t' '$3 == "exon" && match($9, /gene_id "[^"]+"/) {
    g = substr($9, RSTART + 9, RLENGTH - 10); if (!(g in seen)) { seen[g] = 1; print g } }' \
    "$OUT/genes.gtf" > "$OUT/genes.tsv"
fi
{
  printf 'file\tgzip_sha256\tunpacked_sha256\tunpacked_bytes\n'
  for pair in "$FA:genome.fa" "$GTF:genes.gtf"; do
    f=${pair%%:*}; u=${pair##*:}
    printf '%s\t%s\t%s\t%s\n' "$f" "$(awk '{print $1}' "$SRC/$f.sha256")" \
      "$(shasum -a 256 "$OUT/$u" | awk '{print $1}')" "$(wc -c < "$OUT/$u" | tr -d ' ')"
  done
} > "$OUT/SOURCES.tsv"
echo "ref ready: $(wc -l < "$OUT/genes.tsv" | tr -d ' ') genes with exon lines"
