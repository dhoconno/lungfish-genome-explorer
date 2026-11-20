#!/bin/bash
# SPDX-License-Identifier: MIT
# The cell-map route claims of LGE sub-phase 5.5 (lane CM-REPRO, O173 step one, by script).
# Usage: run.sh WORK [STEP ...]
#   WORK   a folder for the runs, logs and claims (made if missing)
#   STEP   any of stage import g2 starsolo pin seeds g1 probes flavors g5 g3 sub100k claims, or all (the default)
# Environment (each optional): LGE_SC_ENV, the env-sc-embed prefix; LGE_RNASEQ, the scratch root of the
# staged data; LGE_CLI, the lungfish-cli built from the lane's base. A run that finished is never redone.
# Every run is `env -i <PATH HOME TMPDIR + the 5.5 C2 variables> python -s -B -P embed.py` (C2-PYFLAGS).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../../.." && pwd)
WORK=${1:?usage: run.sh WORK [STEP ...]}
shift
STEPS=${*:-all}
ENVP=${LGE_SC_ENV:-/Volumes/lge_scratch/lge/rnaseq/env-sc-embed}
RNASEQ=${LGE_RNASEQ:-/Volumes/lge_scratch/lge/rnaseq}
CLI=${LGE_CLI:-$REPO/.build/debug/lungfish-cli}
LOCK=$REPO/scripts/repro/rnaseq/env/explicit-sc-embed-osx-arm64.txt
PY="$ENVP/bin/python"
mkdir -p "$WORK/runs" "$WORK/logs"
WORK=$(cd "$WORK" && pwd)
STAGE=$WORK/stage/pbmc_1k_v3/outs
TENX=$RNASEQ/sc-embed/tenx
G3DEP=$RNASEQ/work/gse183579/deposited
SOLO=$RNASEQ/work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered
G1M=$RNASEQ/work/tenx-controls/truth/SC3pv3_GEX_Human_PBMC/filtered_feature_bc_matrix
G5=(C143 C145 C51 C52)

want() { case " $STEPS " in *" all "*|*" $1 "*) return 0 ;; esac; return 1; }
log() { echo "run.sh: $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Timed runs wait until no other worktree builds, checked empty twice 30 s apart.
wait_quiet() {
  local hits n=0
  while [ $n -lt 2 ]; do
    hits=$(ps -axo pid,command | grep -E 'swift-(build|frontend|test)' | grep -v -F "$REPO" | grep -v grep || true)
    if [ -z "$hits" ]; then n=$((n + 1)); else n=0; log "waiting, another worktree builds"; fi
    [ $n -lt 2 ] && sleep 30
  done
}

ROUTE=(--cells all --feature-type "Gene Expression" --min-cells 3 --target-sum 10000 --n-top-genes 2000
  --hvg-flavor seurat --scale-max 10 --n-comps 50 --svd-solver arpack --pca-seed 0 --n-neighbors 15 --n-pcs 30
  --knn-metric euclidean --knn-transformer sklearn --neighbors-seed 0 --leiden-flavor leidenalg
  --leiden-iterations -1 --leiden-directed true --leiden-use-weights true --resolution 1.0 --leiden-seed 0
  --umap-min-dist 0.5 --umap-spread 1.0 --umap-init spectral --umap-maxiter umap-default --umap-seed 0)
IN_G2=(--sample pbmc_1k_v3 --matrix "$STAGE/filtered_feature_bc_matrix/matrix.mtx.gz"
  --features "$STAGE/filtered_feature_bc_matrix/features.tsv.gz"
  --barcodes "$STAGE/filtered_feature_bc_matrix/barcodes.tsv.gz" --gzip true)
IN_G1=(--sample SC3pv3_GEX_Human_PBMC --matrix "$G1M/matrix.mtx.gz" --features "$G1M/features.tsv.gz"
  --barcodes "$G1M/barcodes.tsv.gz" --gzip true)
IN_SOLO=(--sample pbmc_1k_v3 --matrix "$SOLO/matrix.mtx" --features "$SOLO/features.tsv"
  --barcodes "$SOLO/barcodes.tsv" --gzip false)
IN_G3=()
for d in "$G3DEP"/GSM*; do
  IN_G3+=(--sample "$(basename "$d")" --matrix "$d/matrix.mtx.gz" --features "$d/features.tsv.gz"
    --barcodes "$d/barcodes.tsv.gz" --gzip true)
done

# embed NAME THREADS HASHSEED ARGS...  (later arguments override the route's)
embed() {
  local name=$1 thr=$2 seed=$3 tmp rc
  shift 3
  if [ -f "$WORK/runs/$name/record.json" ]; then log "$name done before"; return 0; fi
  if [ -e "$WORK/runs/$name" ]; then mv "$WORK/runs/$name" "$WORK/runs/$name.failed.$$"; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sc-embed.XXXXXX")
  mkdir -p "$tmp/numba" "$tmp/mpl" "$tmp/xdg"
  log "$name start (threads $thr, PYTHONHASHSEED $seed)"
  set +e
  env -i PATH="$ENVP/bin:/usr/bin:/bin" HOME="$HOME" TMPDIR="$tmp" \
    OMP_NUM_THREADS="$thr" OPENBLAS_NUM_THREADS="$thr" MKL_NUM_THREADS="$thr" \
    VECLIB_MAXIMUM_THREADS="$thr" NUMBA_NUM_THREADS="$thr" PYTHONHASHSEED="$seed" \
    NUMBA_CACHE_DIR="$tmp/numba" MPLCONFIGDIR="$tmp/mpl" XDG_CACHE_HOME="$tmp/xdg" \
    /usr/bin/time -l nice -n 15 "$PY" -s -B -P "$HERE/embed.py" "${ROUTE[@]}" --lock "$LOCK" \
    "$@" --threads "$thr" --out "$WORK/runs/$name" > "$WORK/logs/$name.out" 2> "$WORK/logs/$name.err"
  rc=$?
  set -e
  sleep 2
  ps -axo pid,command | grep -E 'loky|resource_tracker' | grep -v grep > "$WORK/logs/$name.procs" || true
  rm -rf "$tmp"
  log "$name exit $rc, $(grep -E 'real|peak memory footprint' "$WORK/logs/$name.err" | tr -s ' ' | tr '\n' ' ')"
  return $rc
}

if want stage; then
  if [ ! -f "$WORK/stage/pbmc_1k_v3/SHA256SUMS" ]; then
    bash "$HERE/stage_pbmc_1k_v3.sh" "$RNASEQ/tenx/pbmc_1k_v3/pbmc_1k_v3_filtered_feature_bc_matrix.tar.gz" \
      "$RNASEQ/tenx/pbmc_1k_v3/pbmc_1k_v3_metrics_summary.csv" \
      "$TENX/pbmc_1k_v3/extract/analysis/clustering/graphclust/clusters.csv" "$STAGE"
  fi
fi
if want import; then
  RES=$WORK/import/pin.lungfish/Analyses/pbmc_1k_v3.lungfishrnaseq
  if [ ! -f "$RES/rnaseq-result.json" ]; then
    mkdir -p "$WORK/import/pin.lungfish"
    set +e
    "$CLI" import rnaseq "$STAGE" --project "$WORK/import/pin.lungfish" --name pbmc_1k_v3 > "$WORK/logs/import.log" 2>&1
    echo "exit=$?" >> "$WORK/logs/import.log"
    set -e
  fi
  cat "$WORK/logs/import.log"
  grep -q '^exit=0$' "$WORK/logs/import.log" || { log "import rnaseq failed, the stop line of the brief"; exit 1; }
fi
if want g2; then
  embed g2-a 1 0 "${IN_G2[@]}"
  embed g2-b 1 0 "${IN_G2[@]}"
  embed g2-default 1 0 "${IN_G2[@]}" --knn-transformer scanpy-default
fi
if want starsolo; then embed starsolo 1 0 "${IN_SOLO[@]}"; fi
if want pin; then
  PIN=()
  while IFS= read -r x; do PIN+=("$x"); done < <(env -i PATH=/usr/bin:/bin "$PY" -s -B -P "$HERE/prep.py" pin-argv \
    "$WORK/import/pin.lungfish/Analyses/pbmc_1k_v3.lungfishrnaseq")
  embed pin 1 0 "${PIN[@]}"
fi
if want seeds; then
  for s in 1 2 3 4 5 6 7 8 9; do embed "g2-seed$s" 1 0 "${IN_G2[@]}" --leiden-seed "$s"; done
fi
if want g1; then
  wait_quiet; embed g1-a 1 0 "${IN_G1[@]}"
  wait_quiet; embed g1-b 1 0 "${IN_G1[@]}"
  wait_quiet; embed g1-t4 4 0 "${IN_G1[@]}"
fi
if want probes; then
  embed g1-default 1 0 "${IN_G1[@]}" --knn-transformer scanpy-default
  embed g1-hash1 1 1 "${IN_G1[@]}" --allow-hash-seed 1
fi
if want flavors; then
  IG=(--leiden-flavor igraph --leiden-directed false)
  wait_quiet; embed g1-igraph-a 1 0 "${IN_G1[@]}" "${IG[@]}"
  wait_quiet; embed g1-igraph-b 1 0 "${IN_G1[@]}" "${IG[@]}"
  wait_quiet; embed g1-igraph-t4 4 0 "${IN_G1[@]}" "${IG[@]}"
fi
if want g5; then
  if [ ! -f "$WORK/gse145926/C52/SHA256SUMS" ]; then
    env -i PATH=/usr/bin:/bin "$PY" -s -B -P "$HERE/prep.py" gse145926 "$RNASEQ/sc-embed/gse145926" \
      "$RNASEQ/sc-embed/labels/GSE145926-github/all.cell.annotation.meta.txt" "$WORK/gse145926" \
      "$(IFS=,; echo "${G5[*]}")" > "$WORK/logs/gse145926-prep.log" 2>&1 || { cat "$WORK/logs/gse145926-prep.log"; exit 1; }
  fi
  for s in "${G5[@]}"; do
    d=$WORK/gse145926/$s/filtered_feature_bc_matrix
    embed "g5-$s" 1 0 --sample "$s" --matrix "$d/matrix.mtx.gz" --features "$d/features.tsv.gz" \
      --barcodes "$d/barcodes.tsv.gz" --gzip true
  done
fi
if want g3; then
  wait_quiet; embed g3-a 1 0 "${IN_G3[@]}" --n-pcs 20 --resolution 0.8
  wait_quiet; embed g3-b 1 0 "${IN_G3[@]}" --n-pcs 20 --resolution 0.8
  wait_quiet; embed g3-t4 4 0 "${IN_G3[@]}" --n-pcs 20 --resolution 0.8
fi
if want sub100k; then
  if [ ! -f "$WORK/sub100k.tsv" ]; then
    SPECS=()
    for d in "$G3DEP"/GSM*; do SPECS+=("$(basename "$d")=$d/barcodes.tsv.gz"); done
    env -i PATH=/usr/bin:/bin "$PY" -s -B -P "$HERE/prep.py" subsample 100000 0 "$WORK/sub100k.tsv" "${SPECS[@]}" \
      > "$WORK/logs/sub100k-prep.log"
  fi
  wait_quiet; embed g3-sub100k 1 0 "${IN_G3[@]}" --n-pcs 20 --resolution 0.8 --cells "$WORK/sub100k.tsv"
fi
if want claims; then
  env -i PATH=/usr/bin:/bin "$PY" -s -B -P "$HERE/claims.py" "$WORK" "$RNASEQ" "$HERE/claims.tsv"
fi
log "steps done: $STEPS"
