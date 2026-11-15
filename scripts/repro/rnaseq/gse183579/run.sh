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
if has labels; then
  $NICE $PY "$HERE/labels.py" "$WORK" "$HERE/runs.tsv" | tee "$WORK/logs/labels.log"
  # the unfitted row of ruling ADJ-SC gse183579 Q2: QC fixed before looking, labels one to one
  QC_FIXED=200,20 LABELS_OUT=labels_unfitted $NICE $PY "$HERE/labels.py" "$WORK" "$HERE/runs.tsv" \
    | tee "$WORK/logs/labels_unfitted.log"
fi
if has claims; then
  $NICE $PY "$HERE/claims.py" "$WORK" "$HERE/runs.tsv" "$HERE/claims.tsv" | tee "$WORK/logs/claims.log"
fi

# lge_pseudobulk (RS-PSEUDOBULK, not in the default list): lungfish-cli (LGE_CLI) imports the 8 STARsolo libraries with
# their animals from samples.tsv, then sums them by a label table cut from labels/cells.tsv.gz (pass_qc 1, source ours),
# under WORK/lge/${LGE_RUN:-RS-PSEUDOBULK}. pseudobulk_check.py sums the same matrix text by the same table and compares
# every cell of the result's table, and the groups it leaves out are compared with the record's. The largest library
# (LGE_LARGEST) is then imported and summed alone the same way, and logs/figures.txt holds the wall time and memory of
# the four runs (import and leaf, for all 8 libraries and for the largest).
if has lge_pseudobulk; then
  LGE=$WORK/lge/${LGE_RUN:-RS-PSEUDOBULK}; P=$LGE/project; A=$P/Analyses
  rm -rf "$P"; mkdir -p "$A" "$LGE/logs"
  printf 'sample\trun\tanimal\n' > "$LGE/sheet.tsv"; libs=()
  for d in "$WORK"/solo/GSM*; do
    g=$(basename "$d"); libs+=("$d")
    awk -F'\t' -v g="$g" 'NR > 1 && $1 == g {print g "\t" g "\t" $3}' "$WORK/samples.tsv" >> "$LGE/sheet.tsv"
  done
  $PY "$HERE/pseudobulk_check.py" cut "$WORK/labels/cells.tsv.gz" "$WORK/solo" "$LGE/labels.tsv" | tee "$LGE/logs/cut.log"
  /usr/bin/time -l -o "$LGE/logs/import.time" $NICE "${LGE_CLI:?}" import rnaseq "${libs[@]}" --project "$P" \
    --name gse183579-cells --samples "$LGE/sheet.tsv" > "$LGE/logs/import.log" 2>&1 || die "lge import failed"
  /usr/bin/time -l -o "$LGE/logs/pseudobulk.time" $NICE "$LGE_CLI" rnaseq pseudobulk "$A/gse183579-cells.lungfishrnaseq" \
    --labels "$LGE/labels.tsv" --output "$A/gse183579-pseudobulk.lungfishrnaseq" > "$LGE/logs/pseudobulk.log" 2>&1 \
    || die "lge pseudobulk failed (see $LGE/logs/pseudobulk.log)"
  $PY "$HERE/pseudobulk_check.py" check "$WORK/solo" "$LGE/labels.tsv" \
    "$A/gse183579-pseudobulk.lungfishrnaseq/counts/genes.counts.tsv" | tee "$LGE/logs/check.log"
  grep '^dropped: ' "$LGE/logs/check.log" | sed 's/^dropped: //' | sort > "$LGE/dropped.check.txt"
  # ParameterValue writes every value as {"type": ..., "value": ...}, so a list of groups is {"type": "array", "value": [...]}
  # and each group's words are g["value"]["words"]["value"] (read from a record the leaf wrote, 2026-11-15).
  $PY -c 'import json, sys; [print(g["value"]["words"]["value"]) for g in json.load(open(sys.argv[1]))["options"]["resolvedDefaults"]["groupsLeftOut"]["value"]]' \
    "$A/gse183579-pseudobulk.lungfishrnaseq/.lungfish-provenance.json" | sort > "$LGE/dropped.record.txt"
  cmp -s "$LGE/dropped.check.txt" "$LGE/dropped.record.txt" && echo "dropped groups: equal to the record's" \
    || echo "dropped groups: DIFFER from the record's"
  # The largest library alone (LGE_LARGEST, GSM5560898 holds the biggest matrix.mtx), for the leaf's wall time and memory
  # on one matrix. Its labels are that library's rows of the same table.
  big=${LGE_LARGEST:-GSM5560898}; B=$LGE/largest; BA=$B/project/Analyses
  rm -rf "$B"; mkdir -p "$BA"
  awk -F'\t' -v g="$big" 'NR == 1 || $1 == g' "$LGE/sheet.tsv" > "$B/sheet.tsv"
  awk -F'\t' -v g="$big" 'NR == 1 || $1 == g' "$LGE/labels.tsv" > "$B/labels.tsv"
  /usr/bin/time -l -o "$LGE/logs/largest.import.time" $NICE "$LGE_CLI" import rnaseq "$WORK/solo/$big" --project "$B/project" \
    --name largest-cells --samples "$B/sheet.tsv" > "$LGE/logs/largest.import.log" 2>&1 || die "lge import of $big failed"
  /usr/bin/time -l -o "$LGE/logs/largest.pseudobulk.time" $NICE "$LGE_CLI" rnaseq pseudobulk "$BA/largest-cells.lungfishrnaseq" \
    --labels "$B/labels.tsv" --output "$BA/largest-pseudobulk.lungfishrnaseq" > "$LGE/logs/largest.pseudobulk.log" 2>&1 \
    || die "lge pseudobulk of $big failed (see $LGE/logs/largest.pseudobulk.log)"
  $PY "$HERE/pseudobulk_check.py" check "$WORK/solo" "$B/labels.tsv" \
    "$BA/largest-pseudobulk.lungfishrnaseq/counts/genes.counts.tsv" | tee "$LGE/logs/largest.check.log"
  for t in import pseudobulk largest.import largest.pseudobulk; do
    awk -v t="$t" '/real/ {w = $1} /maximum resident/ {m = $1} /peak memory footprint/ {f = $1}
      END {printf "%s: %s s wall, maximum resident set %.1f MiB, peak memory footprint %.1f MiB\n", t, w, m / 2^20, f / 2^20}' \
      "$LGE/logs/$t.time"
  done | tee "$LGE/logs/figures.txt"
fi

# lge_refset (RS-REFSET, gate GR, not in the default list): lungfish-cli (LGE_CLI) builds the reference set in
# each layout under WORK/lge/${LGE_RUN:-RS-REFSET}/root, passed by --storage-root and never exported. Each set
# is checked against ref/ and deleted, and its manifest and tables stay. The root's conda/envs/gffread is the
# RNA-seq pack's, or a link to LGE_PACK_ENV, an installed gffread environment.
if has lge_refset; then
  LGE=$WORK/lge/${LGE_RUN:-RS-REFSET}; E=$DATA/refs/rhesus/ensembl-100
  V=$DATA/refs/sars-cov-2/GCF_009858895.2/GCF_009858895.2_ASM985889v3
  mkdir -p "$LGE/root/conda/envs" "$LGE/logs"; : > "$LGE/gr.txt"
  [ -x "$LGE/root/conda/envs/gffread/bin/gffread" ] || ln -sfn "${LGE_PACK_ENV:?no gffread in the root}" "$LGE/root/conda/envs/gffread"
  gr() { echo "GR gse183579 $*" | tee -a "$LGE/gr.txt"; }
  verdict() { [ "$1" = "$2" ] && echo pass || echo FAIL; }
  # the 11 viral genes as ref.sh names them, the deposit's names
  grep '^NC_045512\.2	' "$WORK/ref/genes.gtf" > "$LGE/virus.gtf"
  cut -f1 "$WORK/ref/genes.tsv" > "$LGE/deposit_genes.txt"
  for layout in lge deposit; do
    opts=(--default rhesus/ensembl-100 --genome "$E/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz"
      --annotation "$E/Macaca_mulatta.Mmul_10.100.gtf.gz")
    if [ "$layout" = lge ]; then opts+=(--extra "virus,NC_045512.2,${V}_genomic.fna.gz"); want=35433
    else opts+=(--layout deposit --study GSE183579 --extra "virus,NC_045512.2,${V}_genomic.fna.gz,$LGE/virus.gtf"); want=35443; fi
    rm -rf "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset
    heavy /usr/bin/time -l -o "$LGE/logs/gse183579-$layout.time" $NICE "${LGE_CLI:?}" rnaseq reference-set \
      --storage-root "$LGE/root" "${opts[@]}" > "$LGE/logs/gse183579-$layout.log" 2>&1 || { gr "$layout build FAIL"; continue; }
    set_dir=$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset); d=$LGE/gse183579-$layout
    rm -rf "$d"; mkdir -p "$d"; cp "$set_dir/reference-set.json" "$set_dir"/derived/*.tsv "$d/"
    grep -v '^gene_id	' "$d/genes.tsv" > "$d/rows.tsv"; cut -f1 "$d/rows.tsv" > "$d/ids.txt"
    n=$(wc -l < "$d/ids.txt" | tr -d ' ')
    gr "$layout features $(verdict "$n" "$want") $n of $want ($(awk '/real/ {printf "%s s, ", $1} /maximum resident/ {printf "peak %.1f GB", $1 / 2^30}' "$LGE/logs/gse183579-$layout.time"))"
    mt=$(awk -F'\t' '$4 == "MT"' "$d/rows.tsv" | wc -l | tr -d ' '); pre=$(awk -F'\t' '$2 ~ /^MT-/' "$d/rows.tsv" | wc -l | tr -d ' ')
    gr "$layout mito $(verdict "$mt $pre" "37 0") $mt on MT, $pre named MT-"
    if [ "$layout" = deposit ]; then
      same=$(cmp -s "$d/ids.txt" "$LGE/deposit_genes.txt" && echo "equal in order" || echo differ)
      gr "$layout genes $(verdict "$same" "equal in order") $same to ref/genes.tsv"
      vir=$(awk -F'\t' '$4 == "NC_045512.2" {printf "%s:%s ", $1, $2}' "$d/rows.tsv")
      gr "$layout virus $(verdict "$(echo "$vir" | wc -w | tr -d ' ')" 11) $vir"
    fi
    rm -rf "$set_dir"
  done
fi

# lge_nothost (RS-NOTHOST, gate GN, not in the default list): lungfish-cli (LGE_CLI) builds the deposit-layout set of
# Mmul_10 Ensembl 100 with NC_045512.2 under WORK/lge/${LGE_RUN:-RS-NOTHOST}/root (kept for a rerun, gffread as in
# lge_refset), then imports the 8 STARsolo libraries with --reference-set and each library's viral slice as
# --not-host-bam. compare_lge_gn.py compares the result's cells.sqlite with virus/<GSM>.barcodes.tsv and
# virus/summary.tsv, and logs/import.time holds the import's wall time and memory.
if has lge_nothost; then
  LGE=$WORK/lge/${LGE_RUN:-RS-NOTHOST}; E=$DATA/refs/rhesus/ensembl-100; P=$LGE/project
  V=$DATA/refs/sars-cov-2/GCF_009858895.2/GCF_009858895.2_ASM985889v3
  mkdir -p "$LGE/root/conda/envs" "$LGE/logs"
  [ -x "$LGE/root/conda/envs/gffread/bin/gffread" ] || ln -sfn "${LGE_PACK_ENV:?no gffread in the root}" "$LGE/root/conda/envs/gffread"
  set_dir=$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset 2>/dev/null | head -1)
  if [ -z "$set_dir" ]; then
    grep '^NC_045512\.2	' "$WORK/ref/genes.gtf" > "$LGE/virus.gtf"
    heavy /usr/bin/time -l -o "$LGE/logs/refset.time" $NICE "${LGE_CLI:?}" rnaseq reference-set --storage-root "$LGE/root" \
      --default rhesus/ensembl-100 --genome "$E/Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz" \
      --annotation "$E/Macaca_mulatta.Mmul_10.100.gtf.gz" --layout deposit --study GSE183579 \
      --extra "virus,NC_045512.2,${V}_genomic.fna.gz,$LGE/virus.gtf" > "$LGE/logs/refset.log" 2>&1 || die "lge set failed"
    set_dir=$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset | head -1)
  fi
  libs=(); bams=()
  for d in "$WORK"/solo/GSM*; do
    g=$(basename "$d"); libs+=("$d"); bams+=(--not-host-bam "$g=$WORK/slices/$g.NC_045512.2.bam")
  done
  rm -rf "$P"; mkdir -p "$P"
  /usr/bin/time -l -o "$LGE/logs/import.time" $NICE "${LGE_CLI:?}" import rnaseq "${libs[@]}" --project "$P" \
    --name gse183579-nothost --reference-set "$set_dir" "${bams[@]}" > "$LGE/logs/import.log" 2>&1 \
    || die "lge import failed (see $LGE/logs/import.log)"
  $PY "$HERE/compare_lge_gn.py" "$P/Analyses/gse183579-nothost.lungfishrnaseq" "$WORK/virus" | tee "$LGE/logs/compare.log"
fi
