#!/usr/bin/env bash
# The paper's index as far as its methods say: Ensembl 100 cdna.all plus ncrna, no decoys (none
# named), k = 31 (salmon's default, no k named). A heavy step: run.sh wraps it in heavy.sh.
# Usage: index.sh <paper_tx.fa> <index_dir> <env_prefix> [threads] [ram_limit_gib]
set -euo pipefail
TX=$1; IDX=$2; ENVP=$3; T=${4:-8}; RAM=${5:-16}
if [ -e "$IDX/.complete" ]; then echo "index exists"; exit 0; fi
rm -rf "$IDX.tmp"
"$ENVP/bin/salmon" index -t "$TX" -k 31 -p "$T" --ramLimit "$RAM" -i "$IDX.tmp"
mv "$IDX.tmp" "$IDX"
touch "$IDX/.complete"
du -sh "$IDX"
