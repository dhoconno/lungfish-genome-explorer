#!/usr/bin/env bash
# Stage the Mtb Erdman assembly the paper put in its Cell Ranger reference, by accession,
# with NCBI's md5 checked and a sha256 ledger row for each file.
# The paper prints "GCA_00668235.1" (a digit is missing); the accession is GCA_000668235.1,
# Myco_tube_Erdman_V1 (R2-BIO Q5, R2-STAT fact 8).
# Usage: stage_mtb.sh <data_root> [ledger_owner]
#   data_root holds refs/ and MANIFEST.tsv; files go to refs/mtb/GCA_000668235.1/
set -euo pipefail
DATA=$1; OWNER=${2:-REPRO-GSE296788}
ACC=GCA_000668235.1_Myco_tube_Erdman_V1
URL=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/668/235/$ACC
OUT=$DATA/refs/mtb/GCA_000668235.1
mkdir -p "$OUT"
FILES="md5checksums.txt ${ACC}_assembly_report.txt ${ACC}_genomic.fna.gz ${ACC}_genomic.gtf.gz annotation_hashes.txt"
for f in $FILES; do
  if [ ! -s "$OUT/$f" ]; then
    curl -fsS --retry 3 -m 600 -o "$OUT/$f.part" "$URL/$f"
    mv "$OUT/$f.part" "$OUT/$f"
  fi
done
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for f in $FILES; do
  verified=no
  if [ "$f" != md5checksums.txt ]; then
    want=$(awk -v n="./$f" '$2 == n {print $1}' "$OUT/md5checksums.txt")
    if command -v md5 >/dev/null; then got=$(md5 -q "$OUT/$f"); else got=$(md5sum "$OUT/$f" | awk '{print $1}'); fi
    if [ -n "$want" ]; then
      [ "$want" = "$got" ] || { echo "md5 mismatch $f: want $want got $got" >&2; exit 1; }
      verified=yes
    fi
  fi
  sha=$(shasum -a 256 "$OUT/$f" | awk '{print $1}')
  echo "$sha  $f" > "$OUT/$f.sha256"
  if ! grep -q "^$OUT/$f	" "$DATA/MANIFEST.tsv"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$OUT/$f" "$URL/$f" "$(wc -c < "$OUT/$f" | tr -d ' ')" \
      sha256 "$sha" "$verified" "$now" "$OWNER" >> "$DATA/MANIFEST.tsv"
  fi
  echo "$f md5_verified=$verified sha256=$sha"
done
