#!/usr/bin/env bash
# GSE183579 (Speranza 2022), rhesus BALF and lung 10x 3' v3.1 with SARS-CoV-2 in the
# reference: STARsolo on the 8 subset libraries of RMO2 and RMY4 (rulings/SC-SUBSET), compared
# library by library with the 47 deposited filtered matrices, viral UMIs in cells and in empty
# droplets, and the paper's Fig. 3 share claims on the deposits, then with our 8 matrices
# swapped in.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE183579/{fastq,geo}, refs/, tenx/pbmc_1k_v3 and MANIFEST.tsv
#   stages      stage whitelist ref inputs index align slice compare virus labels claims
#               (default: all, in that order)
# Environment:
#   LOCKS       folder of the shared heavy lock and PAUSE file ("-" runs heavy steps at once)
#   THREADS     threads for STAR (default 8)
#   HEAVY_WAIT  minutes one heavy.sh call waits for the lock (default 60); HEAVY_TRIES calls
#               (default 24) before the chain gives up
#   KEEP_BAM    1 keeps a library's full BAM after its counts pass (the viral slice is always kept)
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-stage whitelist ref inputs index align slice compare virus labels claims}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$ENVP/bin:$PATH"
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}
PY="$ENVP/bin/python3 -I"
NICE="nice -n ${NICE:-15}"
GEO=$DATA/studies/GSE183579/geo
WL_SHA=843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b
mkdir -p "$WORK/logs"
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
die() { echo "run.sh: $*" >&2; exit 1; }
heavy() { # retry heavy.sh while it is refused (exit 75), up to HEAVY_TRIES times
  local i rc
  for i in $(seq 1 "${HEAVY_TRIES:-24}"); do
    bash "$HERE/../gse152418/heavy.sh" "$LOCKS" REPRO-GSE183579 "${HEAVY_WAIT:-60}" "$@"
    rc=$?
    [ $rc -ne 75 ] && return $rc
    echo "heavy step refused (try $i), retrying $(date '+%H:%M:%S')"
  done
  return 75
}

if has stage; then bash "$HERE/stage_virus.sh" "$DATA" || die "virus staging failed"; fi

if has whitelist; then
  wl=$WORK/whitelist/3M-february-2018.txt
  if [ ! -s "$wl" ]; then
    mkdir -p "$WORK/whitelist"
    $PY "$HERE/../tenx-controls/tenx_prep.py" whitelist \
      "$DATA/tenx/pbmc_1k_v3/pbmc_1k_v3_molecule_info.h5" "$wl" || die "whitelist failed"
  fi
  [ "$(shasum -a 256 "$wl" | cut -d' ' -f1)" = "$WL_SHA" ] || die "whitelist sha256 differs from REPRO-10X's"
fi

if has ref; then $NICE bash "$HERE/ref.sh" "$DATA" "$WORK/ref" || die "ref failed"; fi

if has inputs; then
  $PY "$HERE/prep.py" samples "$GEO/GSE183579_series_matrix.txt.gz" "$WORK/samples.tsv" || die samples
  $NICE $PY "$HERE/prep.py" deposits "$GEO/GSE183579_RAW.tar" "$WORK/samples.tsv" \
    "$WORK/ref/genes.tsv" "$WORK/deposited" || die deposits
  $PY "$HERE/figshare.py" "$GEO/OvYFigShare.xlsx" "$WORK/figshare.tsv" || die figshare
  $PY "$HERE/match.py" "$WORK/figshare.tsv" "$WORK/deposited/libraries.tsv" "$HERE/runs.tsv" \
    "$WORK/match.tsv" | tee "$WORK/logs/match.log" || die match
fi

if has index && [ ! -s "$WORK/index/SA" ]; then
  mkdir -p "$WORK/index"
  heavy $NICE /usr/bin/time -l STAR --runMode genomeGenerate --runThreadN "$THREADS" \
    --genomeDir "$WORK/index" --genomeFastaFiles "$WORK/ref/genome.fa" \
    --sjdbGTFfile "$WORK/ref/genes.gtf" --sjdbOverhang 100 --genomeSAsparseD 2 \
    --limitGenomeGenerateRAM 32000000000 --outFileNamePrefix "$WORK/index/" \
    2> "$WORK/logs/index.time" || die "index failed (see logs/index.time)"
fi

# All 8 libraries go in one hold of the lock; solo.sh skips finished libraries on a rerun.
if has align; then
  heavy $NICE bash "$HERE/solo.sh" "$DATA" "$WORK" "$HERE/runs.tsv" "$THREADS" "$LOCKS" \
    || die "align failed or refused"
fi

if has slice; then
  mkdir -p "$WORK/slices"
  for b in "$WORK"/solo/*/Aligned.sortedByCoord.out.bam; do
    [ -e "$b" ] || continue
    g=$(basename "$(dirname "$b")"); s=$WORK/slices/$g.NC_045512.2.bam
    [ -s "$s.bai" ] && continue
    samtools view -b -o "$s" "$b" NC_045512.2 && samtools index "$s"
    samtools idxstats "$b" > "$WORK/slices/$g.idxstats.tsv"
  done
fi

if has compare; then
  $NICE $PY "$HERE/compare.py" "$WORK" "$HERE/runs.tsv" | tee "$WORK/logs/compare.log"
  # A full BAM goes once its library's counts pass the close class (R2 tally, Q4); the viral
  # slice stays. A failing library keeps its BAM.
  if [ "${KEEP_BAM:-0}" != 1 ] && [ -s "$WORK/compare/pass_libraries.txt" ]; then
    while read -r g; do
      [ -s "$WORK/slices/$g.NC_045512.2.bam.bai" ] && rm -f "$WORK/solo/$g/Aligned.sortedByCoord.out.bam" \
        "$WORK/solo/$g/Aligned.sortedByCoord.out.bam.bai"
    done < "$WORK/compare/pass_libraries.txt"
  fi
fi

if has virus; then $NICE $PY "$HERE/virus.py" "$WORK" "$HERE/runs.tsv" | tee "$WORK/logs/virus.log"; fi
if has labels; then $NICE $PY "$HERE/labels.py" "$WORK" "$HERE/runs.tsv" | tee "$WORK/logs/labels.log"; fi
if has claims; then
  $NICE $PY "$HERE/claims.py" "$WORK" "$HERE/runs.tsv" "$HERE/claims.tsv" | tee "$WORK/logs/claims.log"
fi
