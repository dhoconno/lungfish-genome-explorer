#!/usr/bin/env bash
# Run refcheck.py on reference set folders and keep each answer as <out>/<species>-<set>.tsv.
#
# Usage: run_sets.sh <data_root> <out_dir> <species/set>[@KEY=VALUE,KEY=VALUE] ...
#   run_sets.sh /Volumes/lge_scratch/lge/rnaseq out human/gencode-50 rhesus/ensembl-100@mito_genes=37
# Each name that follows @ becomes one --expect flag. The command that ran goes to
# <out>/<species>-<set>.cmd, the errors to .err and the exit status to the log line.
# Both files are streamed at low priority and no copy of the data is written, so the
# pause marker of a download (<data_root>/locks/PAUSE) does not apply to this run.
# Set PYTHON to choose the interpreter.
ROOT=$1; OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
for item in "$@"; do
  set_dir=${item%%@*}
  expects=()
  if [ "$item" != "$set_dir" ]; then
    IFS=',' read -r -a pairs <<< "${item#*@}"
    for p in "${pairs[@]}"; do expects+=(--expect "$p"); done
  fi
  name=${set_dir//\//-}
  cmd=("${PYTHON:-python3}" -I "$HERE/refcheck.py" "$ROOT/refs/$set_dir" ${expects[@]+"${expects[@]}"})
  printf '%s\n' "${cmd[*]}" > "$OUT/$name.cmd"
  nice -n 15 "${cmd[@]}" > "$OUT/$name.tsv" 2> "$OUT/$name.err"
  echo "$set_dir exit=$?"
done
echo "DONE"
