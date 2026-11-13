#!/usr/bin/env bash
# Stage the SARS-CoV-2 reference the paper names (Wuhan-Hu-1, NC_045512.2) from NCBI's
# RefSeq assembly GCF_009858895.2, check each file against NCBI's md5checksums.txt and
# write one ledger row a file (sha256, source_checksum_verified yes or no).
# Usage: stage_virus.sh <data_root> [staged_by]
set -euo pipefail
DATA=$1; WHO=${2:-REPRO-GSE183579}
ACC=GCF_009858895.2_ASM985889v3
URL=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/858/895/$ACC
OUT=$DATA/refs/sars-cov-2/GCF_009858895.2
mkdir -p "$OUT"
cd "$OUT"
row() { # path url verified
  local sha; sha=$(shasum -a 256 "$1" | cut -d' ' -f1)
  grep -q "^$OUT/$1	" "$DATA/MANIFEST.tsv" || printf '%s\t%s\t%s\tsha256\t%s\t%s\t%s\t%s\n' \
    "$OUT/$1" "$2" "$(wc -c < "$1" | tr -d ' ')" "$sha" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WHO" \
    >> "$DATA/MANIFEST.tsv"
}
[ -s md5checksums.txt ] || curl -fsS --retry 3 -o md5checksums.txt "$URL/md5checksums.txt"
for f in ${ACC}_genomic.fna.gz ${ACC}_genomic.gff.gz ${ACC}_genomic.gtf.gz ${ACC}_assembly_report.txt; do
  [ -s "$f" ] || curl -fsS --retry 3 -o "$f" "$URL/$f"
  want=$(awk -v f="./$f" '$2 == f {print $1}' md5checksums.txt)
  got=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "md5 mismatch for $f: want '$want' got '$got'" >&2; exit 1
  fi
  row "$f" "$URL/$f" yes
  echo "$f md5 $got verified"
done
row md5checksums.txt "$URL/md5checksums.txt" no
