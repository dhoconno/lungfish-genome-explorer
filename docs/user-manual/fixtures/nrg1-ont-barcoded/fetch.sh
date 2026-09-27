#!/usr/bin/env bash
# Fetch the six ENA runs of PRJEB62796 (human NRG1 amplicons, Oxford Nanopore
# GridION, Native Barcoding Kit 96 V14) into source/, verifying each file's
# SHA-256 against the values recorded when the fixture was built (2026-09-27).
# source/ is gitignored. subsample.py then cuts the committed fixture out of it.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p source

# run  ENA fastq_ftp path  sha256 (verified 2026-09-27)
RUNS=(
  "ERR12259924 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/024/ERR12259924/ERR12259924.fastq.gz f44be64dedc7da3a6425cfdfa3c996baf8ff1b51964253e8cf3e69531872dc26"
  "ERR12259925 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/025/ERR12259925/ERR12259925.fastq.gz c2d14b99b03f98237c7dd5a4a1d25e1c3854bed1755b5e930ae283e960fc09df"
  "ERR12259926 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/026/ERR12259926/ERR12259926.fastq.gz bd728b48f1459f2556cf65d3e0870f7f8c7b0e017bcef814d0517c1ed3c6e45a"
  "ERR12259928 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/028/ERR12259928/ERR12259928.fastq.gz 4175745a17f3fbd1f4009d680eaadc4cbb5abf068f9f004661b2226b2881ff97"
  "ERR12259929 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/029/ERR12259929/ERR12259929.fastq.gz 20c0ed5681e7286ba4afd10efbb79483e090237d2225700ee5f4c8cb26e987fc"
  "ERR12259930 ftp.sra.ebi.ac.uk/vol1/fastq/ERR122/030/ERR12259930/ERR12259930.fastq.gz 6af49309c8ab45a79cf26b5556d2f6e3e61e08d75b2733c58dcd82c79e99d2e1"
)

for entry in "${RUNS[@]}"; do
  set -- $entry
  acc=$1; url=$2; want=$3
  out="source/$acc.fastq.gz"
  if [ ! -s "$out" ]; then
    echo "fetching $acc"
    curl -sSL -o "$out" "https://$url"
  fi
  got=$(shasum -a 256 "$out" | cut -c1-64)
  if [ "$got" != "$want" ]; then
    echo "sha256 mismatch for $acc: got $got, want $want" >&2
    exit 1
  fi
  echo "$acc ok ($(wc -c < "$out" | tr -d ' ') bytes)"
done
