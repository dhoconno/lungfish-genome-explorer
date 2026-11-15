#!/usr/bin/env bash
# SEQC/MAQC-III (GSE47774), BGI samples A to D, libraries 1 to 5, lane L01: salmon with
# selective alignment against a decoy-aware Ensembl 100 index plus ERCC92, tximport to genes,
# limma A against B, and the paper's built-in truths scored on ours and on the deposited
# counts of the same 20 libraries. Optional STAR cross-route on a few runs.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root  holds studies/GSE47774/{fastq,geo,truth} and refs/human/ensembl-100
#   stages     ref index quant repeat gene de truth claims bias star (default: ref to claims, no repeat),
#              and outside the default lge_import lge_refset lge_index lge_quant, or lge for the last three
# Environment:
#   LOCKS      folder for the shared heavy lock (mkdir LOCKS/heavy around a heavy step);
#              "-" or unset runs heavy steps at once
#   THREADS    threads for heavy steps (default 8); QTHREADS for salmon quant (default 6)
#   STAR_RUNS  runs for the cross-route (default SRR896663 SRR896743, libraries A_1 and B_1)
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-ref index quant gene de truth claims}
# The word lge runs lge_refset, lge_index and lge_quant in one root, WORK/lge/${LGE_RUN:-LGE} (X1, packaged CLI).
case " $STAGES " in *" lge "*) STAGES="$STAGES lge_refset lge_index lge_quant"; LGE_RUN=${LGE_RUN:-LGE} ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE47774
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}; QTHREADS=${QTHREADS:-6}
STAR_RUNS=${STAR_RUNS:-SRR896663 SRR896743}
PY="$ENVP/bin/python3 -I"; RS="$ENVP/bin/Rscript --vanilla"
NICE="nice -n ${NICE:-15}"
mkdir -p "$WORK/logs"
heavy() { bash "$HERE/heavy.sh" "$LOCKS" REPRO-C1 "${HEAVY_WAIT:-240}" "$@"; }
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

has ref && $NICE bash "$HERE/ref.sh" "$DATA/refs/human/ensembl-100" "$STUDY/truth/ercc/ERCC92.zip" "$WORK/ref" "$ENVP"

has index && heavy $NICE bash "$HERE/index.sh" "$WORK/ref" "$WORK/salmon_index" "$ENVP" "$THREADS" 16

if has quant; then
  tail -n +2 "$HERE/samples.tsv" | cut -f1 | while read -r run; do
    # Ready when both mates have a ledger row whose source check is "yes" (ENA md5) or
    # "derived" (converted from an .sra whose md5 matched).
    nled=$(awk -F'\t' -v r="/fastq/${run}_" 'index($1, r) && ($6 == "yes" || $6 == "derived")' "$DATA/MANIFEST.tsv" | wc -l)
    if [ "$nled" -ge 2 ] && [ ! -e "$STUDY/fastq/${run}_1.fastq.gz.aria2" ] && [ ! -e "$STUDY/fastq/${run}_2.fastq.gz.aria2" ]; then
      $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant" "$ENVP" "$QTHREADS"
    else
      echo "$run not staged yet"
    fi
  done
fi

# salmon 2.6 and later quantify deterministically: the same run at another thread count must
# give the same quant.sf bytes. One run is enough to show it.
if has repeat; then
  mkdir -p "$WORK/claims"
  run=${REPEAT_RUN:-SRR896679}
  $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant_repeat" "$ENVP" 3
  if cmp -s "$WORK/quant/$run/quant.sf" "$WORK/quant_repeat/$run/quant.sf"; then
    echo "repeat $run at 3 threads: quant.sf identical" | tee "$WORK/claims/repeat.txt"
  else
    echo "repeat $run at 3 threads: quant.sf differs" | tee "$WORK/claims/repeat.txt"
  fi
fi

has gene && $NICE $RS "$HERE/gene.R" "$WORK/quant" "$HERE/samples.tsv" "$WORK/ref/tx2gene.tsv" "$WORK/gene"

if has de; then
  mkdir -p "$WORK/deposited"
  $PY "$HERE/deposited.py" "$STUDY/geo/GSE47774_SEQC_ILM_BGI.txt.gz" "$STUDY/truth/ucsc-hg19-refgene/refGene.txt.gz" \
    "$HERE/samples.tsv" "$WORK/deposited/deposited"
  $NICE $RS "$HERE/de.R" "$WORK/deposited/deposited_counts.tsv" "$WORK/deposited/de_AB_deposited.tsv"
  $NICE $RS "$HERE/de.R" "$WORK/gene/gene_counts.tsv" "$WORK/gene/de_AB_ours.tsv"
fi

if has truth; then
  mkdir -p "$WORK/truth"
  $PY "$HERE/taqman.py" "$STUDY/truth/gpl4097/GPL4097_family.soft.gz" "$STUDY/truth/gpl4097/GPL4097.annot.gz" "$WORK/truth/taqman.tsv"
fi

if has claims; then
  $NICE $PY "$HERE/compare.py" --gene-dir "$WORK/gene" --genes "$WORK/ref/genes.tsv" \
    --deposited "$WORK/deposited/deposited_counts.tsv" --de-ours "$WORK/gene/de_AB_ours.tsv" \
    --de-deposited "$WORK/deposited/de_AB_deposited.tsv" --taqman "$WORK/truth/taqman.tsv" \
    --ercc-conc "$STUDY/truth/ercc/cms_095046.txt" --out "$WORK/claims" > "$WORK/logs/compare.log"
  $PY "$HERE/claims.py" "$WORK/claims/metrics.json" "$WORK/claims/claims.tsv"
fi

# The same quant with salmon's sequence and GC bias models, scored the same way, to see which
# truths the flags move.
if has bias; then
  tail -n +2 "$HERE/samples.tsv" | cut -f1 | while read -r run; do
    SALMON_EXTRA="--seqBias --gcBias" $NICE bash "$HERE/quant.sh" "$WORK/salmon_index" "$STUDY/fastq" "$run" "$WORK/quant_gcbias" "$ENVP" "$QTHREADS"
  done
  $NICE $RS "$HERE/gene.R" "$WORK/quant_gcbias" "$HERE/samples.tsv" "$WORK/ref/tx2gene.tsv" "$WORK/gene_gcbias"
  $NICE $RS "$HERE/de.R" "$WORK/gene_gcbias/gene_counts.tsv" "$WORK/gene_gcbias/de_AB_ours.tsv"
  mkdir -p "$WORK/claims_gcbias"
  [ -s "$WORK/claims/repeat.txt" ] && cp "$WORK/claims/repeat.txt" "$WORK/claims_gcbias/"
  $NICE $PY "$HERE/compare.py" --gene-dir "$WORK/gene_gcbias" --genes "$WORK/ref/genes.tsv" \
    --deposited "$WORK/deposited/deposited_counts.tsv" --de-ours "$WORK/gene_gcbias/de_AB_ours.tsv" \
    --de-deposited "$WORK/deposited/de_AB_deposited.tsv" --taqman "$WORK/truth/taqman.tsv" \
    --ercc-conc "$STUDY/truth/ercc/cms_095046.txt" --out "$WORK/claims_gcbias" > "$WORK/logs/compare_gcbias.log"
  $PY "$HERE/claims.py" "$WORK/claims_gcbias/metrics.json" "$WORK/claims_gcbias/claims.tsv"
fi

# Lane evidence of RS-BULK-IMPORT, outside the default stages: LGE_CLI imports the salmon folders of quant/ that
# gene.R reads, labelled <sample>_<library> as gene.R:14, with gene sums through ref/tx2gene.tsv.
if has lge_import; then
  : "${LGE_CLI:?set LGE_CLI to a lungfish-cli}"
  LGE_OUT=$WORK/lge/${LGE_RUN:-RS-BULK-IMPORT}
  mkdir -p "$LGE_OUT/project.lungfish"
  printf 'run\tsample\tgroup\n' > "$LGE_OUT/sheet.tsv"
  LGE_DIRS=()
  while IFS=$'\t' read -r run sample library _; do
    [ "$run" = run ] && continue
    [ -s "$WORK/quant/$run/quant.sf" ] || continue
    printf '%s\t%s_%s\t%s\n' "$run" "$sample" "$library" "$sample" >> "$LGE_OUT/sheet.tsv"
    LGE_DIRS+=("$WORK/quant/$run")
  done < "$HERE/samples.tsv"
  "$LGE_CLI" import rnaseq "${LGE_DIRS[@]}" --project "$LGE_OUT/project.lungfish" --name seqc-c1 \
    --tx2gene "$WORK/ref/tx2gene.tsv" --samples "$LGE_OUT/sheet.tsv"
fi

if has star; then
  heavy $NICE bash "$HERE/star.sh" index "$WORK/ref" "$WORK/star_index" "$ENVP" "$THREADS"
  for run in $STAR_RUNS; do
    heavy $NICE bash "$HERE/star.sh" align "$WORK/star_index" "$STUDY/fastq" "$run" "$WORK/star" "$ENVP" "$THREADS"
    $NICE bash "$HERE/star.sh" count "$WORK/ref" "$run" "$WORK/star" "$ENVP" "$QTHREADS"
  done
  $NICE $PY "$HERE/routes.py" "$WORK" "$HERE/samples.tsv" $STAR_RUNS > "$WORK/logs/routes.log"
fi

# lge_refset (RS-REFSET, gate GR, not in the default list): lungfish-cli (LGE_CLI) builds Ensembl 100 GRCh38 with
# ERCC92 as a spike-in under WORK/lge/${LGE_RUN:-RS-REFSET}/root, passed by --storage-root and never exported, and
# checks it against ref/ (stage ref first), then deletes it and keeps its manifest and tables. The root's
# conda/envs/gffread is the RNA-seq pack's, or a link to LGE_PACK_ENV, an installed gffread environment.
if has lge_refset; then
  LGE=$WORK/lge/${LGE_RUN:-RS-REFSET}; ENS=$DATA/refs/human/ensembl-100; d=$LGE/seqc-lge
  mkdir -p "$LGE/root/conda/envs" "$LGE/logs"; : > "$LGE/gr.txt"
  [ -x "$LGE/root/conda/envs/gffread/bin/gffread" ] || ln -sfn "${LGE_PACK_ENV:?no gffread in the root}" "$LGE/root/conda/envs/gffread"
  gr() { echo "GR seqc-gse47774 $*" | tee -a "$LGE/gr.txt"; }
  rm -rf "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset
  heavy /usr/bin/time -l -o "$LGE/logs/seqc-lge.time" $NICE "${LGE_CLI:?}" rnaseq reference-set --storage-root "$LGE/root" \
    --species "Homo sapiens" --assembly GRCh38 --annotation-source Ensembl --annotation-release 100 \
    --genome "$ENS/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" --annotation "$ENS/Homo_sapiens.GRCh38.100.gtf.gz" \
    --extra "spike-in,ERCC92,$WORK/ref/ercc/ERCC92.fa" > "$LGE/logs/seqc-lge.log" 2>&1 || { gr "build FAIL"; exit 1; }
  set_dir=$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset)
  rm -rf "$d"; mkdir -p "$d"; cp "$set_dir/reference-set.json" "$set_dir"/derived/*.tsv "$d/"
  gr "build $(awk '/real/ {printf "%s s, ", $1} /maximum resident/ {printf "peak %.1f GB", $1 / 2^30}' "$LGE/logs/seqc-lge.time")"
  if cmp -s "$set_dir/derived/transcripts.fa" <(cat "$WORK/ref/transcripts.fa" "$WORK/ref/ercc/ERCC92.fa"); then
    gr "transcripts.fa pass byte-equal to ref/transcripts.fa then ERCC92.fa"
  else
    gr "transcripts.fa FAIL $(cmp "$set_dir/derived/transcripts.fa" <(cat "$WORK/ref/transcripts.fa" "$WORK/ref/ercc/ERCC92.fa") 2>&1 | head -1)"
  fi
  awk -F'\t' '$1 != "transcript_id" { print $1 "\t" $2 }' "$d/transcripts.tsv" | sort -u > "$d/pairs.txt"
  awk -F'\t' '$1 != "transcript_id" && $1 != "TXNAME" { print $1 "\t" $2 }' "$WORK/ref/tx2gene.tsv" | sort -u > "$LGE/tx2gene_pairs.txt"
  n=$(wc -l < "$d/pairs.txt" | tr -d ' '); m=$(wc -l < "$LGE/tx2gene_pairs.txt" | tr -d ' ')
  if cmp -s "$d/pairs.txt" "$LGE/tx2gene_pairs.txt"; then gr "transcripts.tsv pass $n pairs equal tx2gene.tsv as a set"
  else gr "transcripts.tsv FAIL $n pairs against $m, $(comm -3 "$d/pairs.txt" "$LGE/tx2gene_pairs.txt" | wc -l | tr -d ' ') differ"; fi
  has lge_index || rm -rf "$set_dir"
fi

# lge_index (RS-INDEX, not in the default list): lungfish-cli (LGE_CLI) builds the salmon index of the set that lge_refset
# left under WORK/lge/${LGE_RUN:-RS-INDEX}/root, at nice 15 under the heavy lock, then reuses it on a second call. It cmp's
# the index's nine files with C1's salmon_index/ and quant.sf of SRR896663 with C1's (ADJ-SPIKE-BIO items 5 and 6), then
# removes its quant folder and keeps the root. conda/envs/salmon is the RNA-seq pack's, or a link to LGE_SALMON_ENV
# (default ENVP). The heavy lock's owner is the run's name, not REPRO-C1.
if has lge_index; then
  LGE=$WORK/lge/${LGE_RUN:-RS-INDEX}; mkdir -p "$LGE/root/conda/envs" "$LGE/logs"; : > "$LGE/gi.txt"
  gi() { echo "GI seqc-gse47774 $*" | tee -a "$LGE/gi.txt"; }
  [ -x "$LGE/root/conda/envs/salmon/bin/salmon" ] || ln -sfn "${LGE_SALMON_ENV:-$ENVP}" "$LGE/root/conda/envs/salmon"
  set_id=$(basename "$(ls -d "$LGE/root/rnaseq-reference-sets"/*.lungfishrefset | head -1)" .lungfishrefset)
  bash "$HERE/heavy.sh" "$LOCKS" "${LGE_RUN:-RS-INDEX}" "${HEAVY_WAIT:-240}" /usr/bin/time -l -o "$LGE/logs/index.time" \
    nice -n 15 "${LGE_CLI:?}" rnaseq index --storage-root "$LGE/root" --set "$set_id" --format json \
    > "$LGE/logs/index.json" 2> "$LGE/logs/index.err" || { gi "build FAIL"; exit 1; }
  gi "build $(awk '/real/ {printf "%s s, ", $1} /maximum resident/ {printf "peak %.1f GB", $1 / 2^30}' "$LGE/logs/index.time")"
  /usr/bin/time -l -o "$LGE/logs/reuse.time" "$LGE_CLI" rnaseq index --storage-root "$LGE/root" --set "$set_id" \
    --format json > "$LGE/logs/reuse.json" 2>&1 || { gi "reuse FAIL"; exit 1; }
  if grep -q '"reused":true' "$LGE/logs/reuse.json"; then gi "reuse pass $(awk '/real/ {print $1 " s"}' "$LGE/logs/reuse.time")"
  else gi "reuse FAIL, the second call built again"; fi
  idx=$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$LGE/logs/index.json")
  for f in index.ctab index.ectab index.refinfo index.ssi index.ssi.mphf info.json refseq.bin refseq_offsets.json \
    duplicate_clusters.tsv; do
    if cmp -s "$idx/$f" "$WORK/salmon_index/$f"; then gi "index $f equal"
    else gi "index $f DIFFERS $(cmp "$idx/$f" "$WORK/salmon_index/$f" 2>&1 | head -1)"; fi
  done
  $NICE bash "$HERE/quant.sh" "$idx" "$STUDY/fastq" SRR896663 "$LGE/quant" "$ENVP" "$QTHREADS"
  if cmp -s "$LGE/quant/SRR896663/quant.sf" "$WORK/quant/SRR896663/quant.sf"; then gi "quant.sf SRR896663 equal"
  else gi "quant.sf SRR896663 DIFFERS, first lines: $(diff "$LGE/quant/SRR896663/quant.sf" "$WORK/quant/SRR896663/quant.sf" | head -3 | tr '\n' ' ')"; fi
  rm -rf "$LGE/quant"
fi

# lge_quant (RS-QUANT, gate GS, not in the default list): LGE_CLI imports each staged run of samples.tsv as one bundle named
# <sample>_<library>, reads and order kept (--clumping-tool none --quality-binning none, THREADS), into
# WORK/lge/${LGE_RUN:-RS-QUANT}/project.lungfish, then counts them all in one rnaseq quant (QTHREADS) on the set and index of
# lge_index (LGE_INDEX_ROOT, default WORK/lge/${LGE_RUN:-RS-INDEX}/root), at nice 15 with no heavy lock. It waits while
# LOCKS/PAUSE exists before each import and the quant, and stops when lge_scratch would keep under LGE_KEEP_GB (200) free.
# gs.txt has a GS line a check: the record lines first (ADJ-TAIL item 7), then each quant.sf cmp'ed with quant/ (the first
# that differs ends the compare), IU, num_processed and the four index hashes, then the genes at 4 decimals by LGE_COMPARE
# (RS-BULK-IMPORT's compare_import.py). Then LGE_MEASURE_RUN (default SRR896663, - for none) is imported with the default
# storage settings and counted alone. The bundles stay for the record checks.
if has lge_quant; then
  : "${LGE_CLI:?set LGE_CLI to a lungfish-cli}"
  LGE=$WORK/lge/${LGE_RUN:-RS-QUANT}; P=$LGE/project.lungfish; IROOT=${LGE_INDEX_ROOT:-$WORK/lge/${LGE_RUN:-RS-INDEX}/root}
  mkdir -p "$P" "$LGE/logs"; : > "$LGE/gs.txt"
  gs() { echo "GS seqc-gse47774 $*" | tee -a "$LGE/gs.txt"; }
  held() { while [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; do sleep 60; done; }
  took() { awk '/real/ {printf "%s s", $1} /maximum resident/ {printf ", peak %.1f GB", $1 / 2^30}' "$1"; }
  set_id=$(basename "$(ls -d "$IROOT/rnaseq-reference-sets"/*.lungfishrefset | head -1)" .lungfishrefset)
  key=$(ls "$IROOT/rnaseq-index-cache/$set_id"/salmon-*-k31-genome-decoys/index-key.json) || { gs "no index under $IROOT"; exit 1; }
  lge_in() { # <run> <label> <project> <log tag> [import options]: one bundle, unless it is there
    local run=$1 label=$2 proj=$3 tag=$4 need free; shift 4
    local r1=$STUDY/fastq/${run}_1.fastq.gz r2=$STUDY/fastq/${run}_2.fastq.gz
    [ -d "$proj/Imports/$label.lungfishfastq" ] && return 0
    held
    need=$(( ${LGE_KEEP_GB:-200} + ($(du -k "$r1" "$r2" | awk '{s += $1} END {print s}') >> 19) + 1 ))
    free=$(df -g "$WORK" | awk 'NR == 2 {print $4}')
    [ "$free" -ge "$need" ] || { gs "$tag $run stopped, $free GB free and $need GB needed"; exit 1; }
    /usr/bin/time -l -o "$LGE/logs/$tag-$run.time" $NICE "$LGE_CLI" import fastq "$r1" "$r2" --project "$proj" --name "$label" \
      --threads "$THREADS" "$@" < /dev/null > "$LGE/logs/$tag-$run.log" 2>&1 || { gs "$tag $run FAIL, see logs/$tag-$run.log"; exit 1; }
    gs "$tag $run as $label $(took "$LGE/logs/$tag-$run.time")"
  }
  printf 'run\tsample\tgroup\n' > "$LGE/sheet.tsv"; bundles=()
  while IFS=$'\t' read -r run sample library _; do
    [ "$run" = run ] && continue
    { [ -s "$STUDY/fastq/${run}_1.fastq.gz" ] && [ -s "$STUDY/fastq/${run}_2.fastq.gz" ]; } || { gs "import $run not staged"; continue; }
    lge_in "$run" "${sample}_$library" "$P" import --clumping-tool none --quality-binning none
    printf '%s\t%s_%s\t%s\n' "$run" "$sample" "$library" "$sample" >> "$LGE/sheet.tsv"
    bundles+=("$P/Imports/${sample}_$library.lungfishfastq")
  done < "$HERE/samples.tsv"
  [ "${#bundles[@]}" -gt 0 ] || { gs "no run staged"; exit 1; }
  held
  /usr/bin/time -l -o "$LGE/logs/quant.time" $NICE "$LGE_CLI" rnaseq quant "${bundles[@]}" --project "$P" --name seqc-c1 \
    --set "$set_id" --storage-root "$IROOT" --threads "$QTHREADS" --format json < /dev/null > "$LGE/logs/quant.json" \
    2> "$LGE/logs/quant.err" || { gs "quant FAIL, see logs/quant.err"; exit 1; }
  res=$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' "$LGE/logs/quant.json"); rec=$res/.lungfish-provenance.json
  gs "quant ${#bundles[@]} runs $(took "$LGE/logs/quant.time"), $res"
  ok=1; n=${#bundles[@]}
  for line in "Reads not trimmed" "Poly-G trimming at import: not enabled (no trimmer ran at import)"; do
    c=$( { grep -oF "$line" "$rec" || true; } | wc -l | tr -d ' ')
    if [ "$c" -ge "$n" ]; then gs "record \"$line\" $c times for $n runs"; else gs "record \"$line\" FAIL, $c times for $n runs"; ok=0; fi
  done
  for b in seqBias gcBias posBias; do grep -qE "\"$b\" *: *\"off\"" "$res/rnaseq-result.json" || { gs "route $b not off"; ok=0; }; done
  [ "$ok" = 1 ] && gs "route seqBias gcBias posBias off"
  if [ "$ok" = 1 ]; then
    while IFS=$'\t' read -r run label _; do
      [ "$run" = run ] && continue
      s=$res/source/$label; t=$WORK/quant/$run
      if ! cmp -s "$s/quant.sf" "$t/quant.sf"; then
        gs "quant.sf $run DIFFERS, first lines: $(diff "$s/quant.sf" "$t/quant.sf" | head -3 | tr '\n' ' ')"; ok=0; break
      fi
      fmt=$(sed -n 's/.*"expected_format": *"\([A-Z]*\)".*/\1/p' "$s/lib_format_counts.json")
      np=$(sed -n 's/.*"num_processed": *\([0-9]*\).*/\1/p' "$s/aux_info/meta_info.json")
      npt=$(sed -n 's/.*"num_processed": *\([0-9]*\).*/\1/p' "$t/aux_info/meta_info.json")
      h=0
      for k in index_seq_hash index_name_hash index_decoy_seq_hash index_decoy_name_hash; do
        v=$(sed -n "s/.*\"$k\" *: *\"\([0-9a-f]*\)\".*/\1/p" "$key")
        if [ -n "$v" ] && grep -qF "\"$k\": \"$v\"" "$s/aux_info/meta_info.json" && grep -qF "$v" "$rec"; then h=$((h + 1)); fi
      done
      if [ "$fmt" = IU ] && [ -n "$np" ] && [ "$np" = "$npt" ] && [ "$h" = 4 ]; then
        gs "run $run quant.sf equal, IU, num_processed $np, 4 index hashes equal in meta_info.json and the record"
      else gs "run $run FAIL, format $fmt, num_processed $np against $npt, $h of 4 index hashes"; ok=0; fi
    done < "$LGE/sheet.tsv"
  fi
  if [ "$ok" = 1 ] && [ -n "${LGE_COMPARE:-}" ]; then
    if $NICE $PY "$LGE_COMPARE" --result "$res" --sheet "$LGE/sheet.tsv" --quant "$WORK/quant" \
        --truth "$WORK/gene/gene_counts.tsv" --decimals 4 --library-type IU --out "$LGE/compare" > "$LGE/logs/compare.log" 2>&1; then
      gs "genes pass at 4 decimals, genes.counts.tsv sha256 $(sed -n 's/.*"genes_counts_tsv_sha256": "\([0-9a-f]*\)".*/\1/p' "$LGE/compare/summary.json")"
    else gs "genes FAIL, see compare/summary.json and compare/differences.tsv"; fi
  else gs "genes not compared (a check above failed, or LGE_COMPARE is unset)"; fi
  mr=${LGE_MEASURE_RUN:-SRR896663}
  if [ "$mr" != - ]; then # the default storage settings: clumping and fiveStep
    D=$LGE/default/project.lungfish; mkdir -p "$D"
    ml=$(awk -F'\t' -v r="$mr" '$1 == r {print $2 "_" $3}' "$HERE/samples.tsv")
    if ( lge_in "$mr" "$ml" "$D" default ) && held && /usr/bin/time -l -o "$LGE/logs/default-quant.time" $NICE "$LGE_CLI" \
        rnaseq quant "$D/Imports/$ml.lungfishfastq" --project "$D" --name seqc-c1-default --set "$set_id" --storage-root "$IROOT" \
        --threads "$QTHREADS" --format json < /dev/null > "$LGE/logs/default-quant.json" 2> "$LGE/logs/default-quant.err"; then
      dres=$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' "$LGE/logs/default-quant.json")
      if cmp -s "$dres/source/$ml/quant.sf" "$WORK/quant/$mr/quant.sf"; then gs "default storage $mr quant.sf equal"
      else gs "default storage $mr quant.sf DIFFERS, first lines: $(diff "$dres/source/$ml/quant.sf" "$WORK/quant/$mr/quant.sf" | head -3 | tr '\n' ' ')"; fi
    else gs "default storage $mr FAIL, see logs/default-*"; fi
  fi
fi
