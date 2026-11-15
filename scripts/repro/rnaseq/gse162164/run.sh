#!/usr/bin/env bash
# GSE162164 (C5), human whole blood, TB in advanced HIV, India cohort, 25 runs PE150 (trimmed
# before deposit). salmon on two indexes, gene and symbol tables against the deposited 14,440 x 25
# matrix, and the paper's DE and two-gene signature on the deposit and on ours.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE162164/{fastq,geo,paper}, refs/human/ensembl-100 and MANIFEST.tsv
#   work_dir    derived files; work_dir/../seqc-gse47774 holds REPRO-C1's decoy-aware index
#   env_prefix  the main environment; sva comes from env-r-sva beside it (R_ENV)
#   stages      samples ref supp deposit index quant_paper quant_decoy compare de, or chain
#               (default: chain, which runs them all in the order the shared machine needs), and outside the
#               chain lge_import (RS-BULK-IMPORT) and lge_quant (RS-QUANT), which need LGE_CLI
# Environment:
#   LOCKS       folder of the shared heavy lock; "-" or unset runs the index build at once
#   DECOY_DIR   REPRO-C1's work folder (default work_dir/../seqc-gse47774)
#   R_ENV       the R environment with sva (default env-r-sva beside env_prefix)
#   THREADS     threads for salmon (default 6); HEAVY_WAIT minutes a lock attempt (default 120)
#   LATE_WAIT   minutes to wait for runs still downloading (default 360)
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-chain}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE162164
DECOY_DIR=${DECOY_DIR:-$(dirname "$WORK")/seqc-gse47774}
R_ENV=${R_ENV:-$(dirname "$ENVP")/env-r-sva}
LOCKS=${LOCKS:--}; THREADS=${THREADS:-6}
PY="$ENVP/bin/python3 -I"; RS="$R_ENV/bin/Rscript --vanilla"
NICE="nice -n ${NICE:-15}"
SHEET=$HERE/samples.tsv
mkdir -p "$WORK/logs"
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

samples() { $PY "$HERE/samples.py" "$STUDY" "$WORK/samples.tsv" && cmp "$WORK/samples.tsv" "$SHEET"; }
ref() { $NICE bash "$HERE/ref.sh" "$DATA/refs/human/ensembl-100" "$WORK/ref" "$ENVP"; }
supp() { # Supplementary Table 2 (the DEG lists) from Europe PMC's supplementary bundle
  local d=$STUDY/paper/supp
  mkdir -p "$d" "$WORK/supp"
  [ -s "$d/PMC7937880_supp.zip" ] || curl -fsS --retry 3 -o "$d/PMC7937880_supp.zip" \
    "https://www.ebi.ac.uk/europepmc/webservices/rest/PMC7937880/supplementaryFiles"
  mkdir -p "$d/x"; unzip -o -q "$d/PMC7937880_supp.zip" 'Table_2*' -d "$d/x"
  $PY "$HERE/xlsx2tsv.py" "$d/x/Table_2.XLSX" "$WORK/supp/table2"
}
deposit() {
  mkdir -p "$WORK/deposited"
  gunzip -c "$STUDY/geo/GSE162164_counts.txt.gz" | awk 'NR == 1 {print "gene\t" $0; next} {print}' \
    > "$WORK/deposited/counts.tsv"
}
index() { # heavy: reruns heavy.sh while it is refused (exit 75), until the index exists
  until [ -e "$WORK/salmon_index_paper/.complete" ]; do
    rc=0
    bash "$HERE/heavy.sh" "$LOCKS" REPRO-C5 "${HEAVY_WAIT:-120}" bash -c \
      "touch '$WORK/quant_decoy.STOP'; $NICE bash '$HERE/index.sh' '$WORK/ref/paper_tx.fa' \
       '$WORK/salmon_index_paper' '$ENVP' $THREADS 16" || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 75 ] || { log "index failed rc $rc"; return "$rc"; }
  done
}
quant_paper() { $NICE bash "$HERE/quant.sh" "$DATA" "$SHEET" "$WORK/salmon_index_paper" "$WORK/quant_paper" "$ENVP" "$THREADS"; }
quant_decoy() { STOP_FILE=${STOP_FILE:-} $NICE bash "$HERE/quant.sh" "$DATA" "$SHEET" "$DECOY_DIR/salmon_index" "$WORK/quant_decoy" "$ENVP" "$THREADS"; }
compare() {
  [ -d "$WORK/quant_paper" ] && $NICE $PY "$HERE/compare.py" --quant "$WORK/quant_paper" \
    --tx2gene "$WORK/ref/tx2gene_paper.tsv" --fasta-order "$WORK/ref/paper_tx.fa" --samples "$SHEET" \
    --deposit "$STUDY/geo/GSE162164_counts.txt.gz" --out "$WORK/compare_paper"
  [ -d "$WORK/quant_decoy" ] && $NICE $PY "$HERE/compare.py" --quant "$WORK/quant_decoy" \
    --tx2gene "$DECOY_DIR/ref/tx2gene.tsv" --fasta-order "$DECOY_DIR/ref/transcripts_ercc.fa" \
    --samples "$SHEET" --deposit "$STUDY/geo/GSE162164_counts.txt.gz" --out "$WORK/compare_decoy"
  return 0
}
de() { # step A on the deposit, step B on ours (gene sums, the tximport default), same script
  local t2=$WORK/supp/table2.1.India_DEGS.tsv
  $NICE $RS "$HERE/de.R" "$WORK/deposited/counts.tsv" "$SHEET" "$t2" "$WORK/de_deposit" 1
  for arm in paper decoy; do
    f=$WORK/compare_$arm/ours_sum_by_symbol.tsv
    [ -s "$f" ] && $NICE $RS "$HERE/de.R" "$f" "$SHEET" "$t2" "$WORK/de_${arm}_sum" "$([ $arm = paper ] && echo 1 || echo 0)"
  done
  return 0
}
nquant() { ls "$WORK/$1"/*/quant.sf 2>/dev/null | wc -l | tr -d ' '; }
lge_import() { # lane evidence of RS-BULK-IMPORT, outside the chain: LGE_CLI imports the decoy arm with C1's tx2gene
  : "${LGE_CLI:?set LGE_CLI to a lungfish-cli}"
  local out=$WORK/lge/${LGE_RUN:-RS-BULK-IMPORT} run gsm title group rest
  local dirs=()
  mkdir -p "$out/project.lungfish"
  printf 'run\tsample\tgroup\n' > "$out/sheet.tsv"
  while IFS=$'\t' read -r run gsm title group rest; do
    [ "$run" = run ] && continue
    [ -s "$WORK/quant_decoy/$run/quant.sf" ] || continue
    printf '%s\t%s\t%s\n' "$run" "$(printf '%s' "$rest" | cut -f3)" "$group" >> "$out/sheet.tsv"
    dirs+=("$WORK/quant_decoy/$run")
  done < "$SHEET"
  "$LGE_CLI" import rnaseq "${dirs[@]}" --project "$out/project.lungfish" --name gse162164-decoy \
    --tx2gene "$DECOY_DIR/ref/tx2gene.tsv" --samples "$out/sheet.tsv"
}
lge_quant() { # lane evidence of RS-QUANT (gate GC), outside the chain: seqc-gse47774/run.sh's lge_quant on C1's set and index
  # (LGE_INDEX_ROOT, default DECOY_DIR/lge/${LGE_RUN:-RS-INDEX}/root, as quant_decoy used C1's index), each run a bundle named
  # by its deposit column (IMPORT_THREADS, default 8), salmon at THREADS, against quant_decoy/ with ISR and the genes of
  # compare_decoy/gene_id_counts.tsv at 3 decimals by LGE_COMPARE. GC lines in gc.txt. The bundles stay for the record checks.
  : "${LGE_CLI:?set LGE_CLI to a lungfish-cli}"
  local out=$WORK/lge/${LGE_RUN:-RS-QUANT} iroot=${LGE_INDEX_ROOT:-$DECOY_DIR/lge/${LGE_RUN:-RS-INDEX}/root}
  local p run gsm title group age sex dep spots r1 r2 need free set_id key res rec ok n c line s t fmt np npt h k v b
  local bundles=()
  p=$out/project.lungfish; mkdir -p "$p" "$out/logs"; : > "$out/gc.txt"
  gc() { echo "GC gse162164 $*" | tee -a "$out/gc.txt"; }
  held() { while [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; do sleep 60; done; }
  took() { awk '/real/ {printf "%s s", $1} /maximum resident/ {printf ", peak %.1f GB", $1 / 2^30}' "$1"; }
  set_id=$(basename "$(ls -d "$iroot/rnaseq-reference-sets"/*.lungfishrefset | head -1)" .lungfishrefset)
  key=$(ls "$iroot/rnaseq-index-cache/$set_id"/salmon-*-k31-genome-decoys/index-key.json) || { gc "no index under $iroot"; exit 1; }
  printf 'run\tsample\tgroup\n' > "$out/sheet.tsv"
  while IFS=$'\t' read -r run gsm title group age sex dep spots; do
    [ "$run" = run ] && continue
    r1=$STUDY/fastq/${run}_1.fastq.gz; r2=$STUDY/fastq/${run}_2.fastq.gz
    { [ -s "$r1" ] && [ -s "$r2" ]; } || { gc "import $run not staged"; continue; }
    if [ ! -d "$p/Imports/$dep.lungfishfastq" ]; then
      held
      need=$(( ${LGE_KEEP_GB:-200} + ($(du -k "$r1" "$r2" | awk '{s += $1} END {print s}') >> 19) + 1 ))
      free=$(df -g "$WORK" | awk 'NR == 2 {print $4}')
      [ "$free" -ge "$need" ] || { gc "import $run stopped, $free GB free and $need GB needed"; exit 1; }
      /usr/bin/time -l -o "$out/logs/import-$run.time" $NICE "$LGE_CLI" import fastq "$r1" "$r2" --project "$p" --name "$dep" \
        --clumping-tool none --quality-binning none --threads "${IMPORT_THREADS:-8}" < /dev/null > "$out/logs/import-$run.log" 2>&1 \
        || { gc "import $run FAIL, see logs/import-$run.log"; exit 1; }
      gc "import $run as $dep $(took "$out/logs/import-$run.time")"
    fi
    printf '%s\t%s\t%s\n' "$run" "$dep" "$group" >> "$out/sheet.tsv"; bundles+=("$p/Imports/$dep.lungfishfastq")
  done < "$SHEET"
  [ "${#bundles[@]}" -gt 0 ] || { gc "no run staged"; exit 1; }
  held
  /usr/bin/time -l -o "$out/logs/quant.time" $NICE "$LGE_CLI" rnaseq quant "${bundles[@]}" --project "$p" --name gse162164 \
    --set "$set_id" --storage-root "$iroot" --threads "$THREADS" --format json < /dev/null > "$out/logs/quant.json" \
    2> "$out/logs/quant.err" || { gc "quant FAIL, see logs/quant.err"; exit 1; }
  res=$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' "$out/logs/quant.json"); rec=$res/.lungfish-provenance.json
  gc "quant ${#bundles[@]} runs $(took "$out/logs/quant.time"), $res"
  ok=1; n=${#bundles[@]}
  for line in "Reads not trimmed" "Poly-G trimming at import: not enabled (no trimmer ran at import)"; do
    c=$( { grep -oF "$line" "$rec" || true; } | wc -l | tr -d ' ')
    if [ "$c" -ge "$n" ]; then gc "record \"$line\" $c times for $n runs"; else gc "record \"$line\" FAIL, $c times for $n runs"; ok=0; fi
  done
  for b in seqBias gcBias posBias; do grep -qE "\"$b\" *: *\"off\"" "$res/rnaseq-result.json" || { gc "route $b not off"; ok=0; }; done
  [ "$ok" = 1 ] && gc "route seqBias gcBias posBias off"
  if [ "$ok" = 1 ]; then
    while IFS=$'\t' read -r run dep group; do
      [ "$run" = run ] && continue
      s=$res/source/$dep; t=$WORK/quant_decoy/$run
      if ! cmp -s "$s/quant.sf" "$t/quant.sf"; then
        gc "quant.sf $run DIFFERS, first lines: $(diff "$s/quant.sf" "$t/quant.sf" | head -3 | tr '\n' ' ')"; ok=0; break
      fi
      fmt=$(sed -n 's/.*"expected_format": *"\([A-Z]*\)".*/\1/p' "$s/lib_format_counts.json")
      np=$(sed -n 's/.*"num_processed": *\([0-9]*\).*/\1/p' "$s/aux_info/meta_info.json")
      npt=$(sed -n 's/.*"num_processed": *\([0-9]*\).*/\1/p' "$t/aux_info/meta_info.json")
      h=0
      for k in index_seq_hash index_name_hash index_decoy_seq_hash index_decoy_name_hash; do
        v=$(sed -n "s/.*\"$k\" *: *\"\([0-9a-f]*\)\".*/\1/p" "$key")
        if [ -n "$v" ] && grep -qF "\"$k\": \"$v\"" "$s/aux_info/meta_info.json" && grep -qF "$v" "$rec"; then h=$((h + 1)); fi
      done
      if [ "$fmt" = ISR ] && [ -n "$np" ] && [ "$np" = "$npt" ] && [ "$h" = 4 ]; then
        gc "run $run quant.sf equal, ISR, num_processed $np, 4 index hashes equal in meta_info.json and the record"
      else gc "run $run FAIL, format $fmt, num_processed $np against $npt, $h of 4 index hashes"; ok=0; fi
    done < "$out/sheet.tsv"
  fi
  if [ "$ok" = 1 ] && [ -n "${LGE_COMPARE:-}" ]; then
    if $NICE $PY "$LGE_COMPARE" --result "$res" --sheet "$out/sheet.tsv" --quant "$WORK/quant_decoy" \
        --truth "$WORK/compare_decoy/gene_id_counts.tsv" --decimals 3 --library-type ISR --out "$out/compare" \
        > "$out/logs/compare.log" 2>&1; then
      gc "genes pass at 3 decimals, genes.counts.tsv sha256 $(sed -n 's/.*"genes_counts_tsv_sha256": "\([0-9a-f]*\)".*/\1/p' "$out/compare/summary.json")"
    else gc "genes FAIL, see compare/summary.json and compare/differences.tsv"; fi
  else gc "genes not compared (a check above failed, or LGE_COMPARE is unset)"; fi
}

if has chain; then
  log "chain start"; samples; ref; supp; deposit
  rm -f "$WORK/quant_decoy.STOP"
  # The decoy-aware arm needs no lock, so it runs while the paper index waits for the heavy lock.
  # The index step touches quant_decoy.STOP once it holds the lock, and the loop ends between runs.
  STOP_FILE=$WORK/quant_decoy.STOP quant_decoy > "$WORK/logs/quant_decoy_early.log" 2>&1 &
  early=$!
  index; log "index ready"
  wait "$early" || true; rm -f "$WORK/quant_decoy.STOP"; log "early decoy loop ended"
  quant_paper; log "paper quant pass done ($(nquant quant_paper) runs)"
  quant_decoy; log "decoy quant pass done ($(nquant quant_decoy) runs)"
  compare; de; log "first analysis done"
  # Runs the bulk downloader is still fetching get quantified when their ledger rows appear.
  deadline=$(( $(date +%s) + ${LATE_WAIT:-360} * 60 ))
  while [ "$(nquant quant_paper)" -lt 25 ] || [ "$(nquant quant_decoy)" -lt 25 ]; do
    [ "$(date +%s)" -ge "$deadline" ] && { log "late runs still missing at the deadline"; break; }
    sleep 600
    before=$(( $(nquant quant_paper) + $(nquant quant_decoy) ))
    quant_paper; quant_decoy
    if [ $(( $(nquant quant_paper) + $(nquant quant_decoy) )) -gt "$before" ]; then
      compare; de; log "analysis redone ($(nquant quant_paper) paper, $(nquant quant_decoy) decoy runs)"
    fi
  done
  log "chain done"; touch "$WORK/CHAIN_DONE"
  exit 0
fi
for s in samples ref supp deposit index quant_paper quant_decoy compare de lge_import lge_quant; do
  if has $s; then log "stage $s"; $s; fi
done
