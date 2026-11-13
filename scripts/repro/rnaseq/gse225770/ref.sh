#!/usr/bin/env bash
# Reference files for the nf-core/rnaseq 3.8.1 star_salmon route, built the way its PREPARE_GENOME does:
#   genome.fa            the Ensembl toplevel FASTA, unpacked (GUNZIP_FASTA)
#   genes.gtf            the Ensembl GTF, unpacked (GUNZIP_GTF), which the STAR index and salmon --geneMap use
#   genes_in_genome.gtf  GTF lines on sequences of the FASTA (GTF_GENE_FILTER)
#   transcripts.fa       spliced transcript sequences (MAKE_TRANSCRIPTS_FASTA, which runs rsem-prepare-reference;
#                        RSEM is not in the environment, so gffread -w stands in, see the README)
#   tx2gene.tsv          transcript, gene, gene name (SALMON_TX2GENE)
#   genes.tsv            gene table for the comparison
# Usage: ref.sh <ref_dir> <fasta_gz> <gtf_gz> <out_dir> <env_prefix> [sequence names to keep, for a small test]
set -euo pipefail
REFDIR=$1; FA_GZ=$2; GTF_GZ=$3; OUT=$4; ENVP=$5; ONLY=${6:-}
HERE=$(cd "$(dirname "$0")" && pwd)
PY="$ENVP/bin/python3 -I"
mkdir -p "$OUT"

for f in "$FA_GZ" "$GTF_GZ"; do (cd "$REFDIR" && shasum -a 256 -c "$f.sha256"); done

if [ -n "$ONLY" ]; then
  # a small test genome made of the named sequences only
  gunzip -c "$REFDIR/$FA_GZ" | awk -v keep="$ONLY" 'BEGIN{n=split(keep,a," ");for(i=1;i<=n;i++)k[a[i]]=1}
    /^>/{split(substr($0,2),h," ");p=(h[1] in k)} p' > "$OUT/genome.fa"
else
  gunzip -c "$REFDIR/$FA_GZ" > "$OUT/genome.fa"
fi
"$ENVP/bin/samtools" faidx "$OUT/genome.fa"
gunzip -c "$REFDIR/$GTF_GZ" > "$OUT/genes.gtf"

$PY "$HERE/gtf_tools.py" filter --gtf "$OUT/genes.gtf" --fasta "$OUT/genome.fa" --out "$OUT/genes_in_genome.gtf"
# gffread adds a CDS=start-end note to each header and RSEM does not, so the header keeps its id only
"$ENVP/bin/gffread" -w - -g "$OUT/genome.fa" "$OUT/genes_in_genome.gtf" | awk '/^>/{print $1; next} {print}' > "$OUT/transcripts.fa"
$PY "$HERE/gtf_tools.py" check --gtf "$OUT/genes_in_genome.gtf" --fasta "$OUT/transcripts.fa"
# nf-core builds the transcript table from the unfiltered GTF, and so does this
$PY "$HERE/gtf_tools.py" tx2gene --gtf "$OUT/genes.gtf" --fasta "$OUT/transcripts.fa" --out "$OUT/tx2gene.tsv"
$PY "$HERE/gtf_tools.py" genes --gtf "$OUT/genes.gtf" --out "$OUT/genes.tsv"

# STAR index and salmon --geneMap take the unfiltered GTF in nf-core. On a test genome with a few
# sequences that GTF names sequences STAR does not have, so the filtered one is used there.
if [ -n "$ONLY" ]; then cp "$OUT/genes_in_genome.gtf" "$OUT/index.gtf"; else cp "$OUT/genes.gtf" "$OUT/index.gtf"; fi
echo "ref done $(date '+%H:%M:%S')"
