#!/usr/bin/env bash
# Decoy-aware salmon index: Ensembl 100 transcripts plus ERCC92, with the whole GRCh38
# primary assembly as decoys (ref.sh writes gentrome.fa and decoys.txt), k = 31.
# Usage: index.sh <ref_dir> <index_dir> <env_prefix> [threads] [ram_limit_gib]
set -euo pipefail
REF=$1; IDX=$2; ENVP=$3; T=${4:-8}; RAM=${5:-16}
if [ -e "$IDX/.complete" ]; then echo "index exists"; exit 0; fi
rm -rf "$IDX.tmp"
"$ENVP/bin/salmon" index -t "$REF/gentrome.fa" -d "$REF/decoys.txt" -k 31 -p "$T" \
  --ramLimit "$RAM" -i "$IDX.tmp"
mv "$IDX.tmp" "$IDX"
touch "$IDX/.complete"
du -sh "$IDX"
