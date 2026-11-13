#!/usr/bin/env bash
# The paper's reference: "the human transcriptome (GRCh38 version 100), comprising mRNA and ncRNA"
# (Kulkarni 2021, Methods, Gene Expression Analysis). That is Ensembl release 100's cdna.all and
# ncrna FASTA files. This script fetches both with Ensembl's CHECKSUMS files when they are absent,
# checks each against Ensembl's BSD sum, writes a sha256 beside it, and builds the concatenated
# transcript FASTA and a transcript to gene table from the FASTA headers.
# Usage: ref.sh <refs_dir> <out_dir> <env_prefix>
#   refs_dir   refs/human/ensembl-100 (the files land here, beside the GTF)
#   out_dir    work folder for paper_tx.fa and tx2gene_paper.tsv
set -euo pipefail
REFS=$1; OUT=$2; ENVP=$3
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=https://ftp.ensembl.org/pub/release-100/fasta/homo_sapiens
mkdir -p "$OUT"
fetch() { # <subdir> <file>
  local sub=$1 f=$2
  if [ ! -s "$REFS/$f" ]; then
    curl -fsS --retry 5 -o "$REFS/$f.part" "$BASE/$sub/$f"
    mv "$REFS/$f.part" "$REFS/$f"
  fi
  [ -s "$REFS/CHECKSUMS.$sub" ] || curl -fsS --retry 5 -o "$REFS/CHECKSUMS.$sub" "$BASE/$sub/CHECKSUMS"
  # Ensembl's CHECKSUMS hold the BSD sum (16-bit checksum and 1 KiB blocks), as cksum -o 1 prints.
  want=$(awk -v f="$f" '$3 == f {print $1, $2}' "$REFS/CHECKSUMS.$sub")
  got=$(cksum -o 1 "$REFS/$f" | awk '{print $1, $2}')
  [ "$want" = "$got" ] || { echo "BSD sum of $f is $got, Ensembl says $want" >&2; exit 1; }
  (cd "$REFS" && shasum -a 256 "$f" > "$f.sha256")
  echo "$f bsd sum $got matches Ensembl, sha256 $(cut -c1-12 "$REFS/$f.sha256")..."
}
fetch cdna Homo_sapiens.GRCh38.cdna.all.fa.gz
fetch ncrna Homo_sapiens.GRCh38.ncrna.fa.gz

if [ ! -s "$OUT/paper_tx.fa" ]; then
  gunzip -c "$REFS/Homo_sapiens.GRCh38.cdna.all.fa.gz" "$REFS/Homo_sapiens.GRCh38.ncrna.fa.gz" \
    > "$OUT/paper_tx.fa.part"
  mv "$OUT/paper_tx.fa.part" "$OUT/paper_tx.fa"
fi
"$ENVP/bin/python3" -I "$HERE/tx2gene.py" "$OUT/paper_tx.fa" "$OUT/tx2gene_paper.tsv"
