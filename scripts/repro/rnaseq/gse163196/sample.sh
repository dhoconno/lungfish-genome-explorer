#!/usr/bin/env bash
# One run of C9 through both UMI routes. Each step writes a .done marker, so a rerun skips it.
# Usage: sample.sh <run> <R1.fastq.gz> <R2.fastq.gz> <out_dir> <env_dir> <star_index> <genes.gtf> <locks_dir|->
#
#  1 extract  umi_tools extract: Read 1 must start with ATCAATC (exact); the next 16 nt are the UMI.
#             Only Read 2 (the transcript) is kept, with the UMI in its name.
#  2 star     STAR, Read 2 single end, unique alignments only (--outFilterMultimapNmax 1, as in the
#             UMI-tools single-cell tutorial the paper cites), coordinate-sorted BAM. Heavy step.
#  3 reads    featureCounts on the STAR BAM: read counts (route R) and a BAM with XT/XS gene tags.
#  4 count    route P (the paper's cited tutorial): umi_tools count --per-gene --method directional.
#  5 dedup    route L (the plan's order): umi_tools dedup --method directional on positions, then
#             featureCounts on the deduplicated BAM.
# STRAND (default 0, the tutorial's featureCounts default) and the thread counts come from the environment.
set -euo pipefail
RUN=$1; R1=$2; R2=$3; OUT=$4; ENV=$5; IDX=$6; GTF=$7; LOCKS=$8
HERE=$(cd "$(dirname "$0")" && pwd)
B=$ENV/bin
STAR_T=${STAR_THREADS:-5}
LT=${LIGHT_THREADS:-2}
STRAND=${STRAND:-0}
STEPS=${STEPS:-"extract star reads count dedup"}
D=$OUT/$RUN
mkdir -p "$D"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $RUN $*"; }
want() { case " $STEPS " in *" $1 "*) return 0;; *) return 1;; esac; }
# A later step run alone waits up to 12 hours for the marker of the step before it.
need() { local n=0; while [ ! -e "$D/$1.done" ]; do n=$((n + 1)); [ $n -gt 1440 ] && { log "no $1.done"; exit 75; }; sleep 30; done; }
TIME="/usr/bin/time -l"

if want extract && [ ! -e "$D/extract.done" ]; then
  log extract start
  $TIME nice -n 15 "$B/umi_tools" extract --extract-method=regex \
      --bc-pattern='^(?P<discard_1>ATCAATC)(?P<umi_1>.{16})' \
      -I "$R1" --read2-in "$R2" --read2-stdout -L "$D/extract.log" 2> "$D/extract.time" \
    | nice -n 15 "$B/pigz" -p 1 > "$D/R2.umi.fastq.gz"
  touch "$D/extract.done"
  log extract end
fi

if want star && [ ! -e "$D/star.done" ]; then
  need extract
  log star wait
  "$HERE/heavy.sh" "$LOCKS" "REPRO-C9 $RUN" 600 $TIME nice -n 15 "$B/STAR" --runThreadN "$STAR_T" \
      --genomeDir "$IDX" --readFilesIn "$D/R2.umi.fastq.gz" --readFilesCommand "$B/pigz" -dc \
      --outFilterMultimapNmax 1 --outSAMtype BAM SortedByCoordinate --limitBAMsortRAM 8000000000 \
      --outFileNamePrefix "$D/" > "$D/star.heavy.log" 2> "$D/star.time"
  nice -n 15 "$B/samtools" index "$D/Aligned.sortedByCoord.out.bam"
  rm -rf "$D/_STARtmp"
  touch "$D/star.done"
  log star end
fi

if want reads && [ ! -e "$D/reads.done" ]; then
  need star
  mkdir -p "$D/fc"
  nice -n 15 "$B/featureCounts" -T "$LT" -s "$STRAND" -a "$GTF" -o "$D/fc_reads.txt" -R BAM --Rpath "$D/fc" \
      "$D/Aligned.sortedByCoord.out.bam" > "$D/fc_reads.log" 2>&1
  nice -n 15 "$B/samtools" sort -@ "$LT" -o "$D/assigned.bam" "$D/fc/Aligned.sortedByCoord.out.bam.featureCounts.bam"
  nice -n 15 "$B/samtools" index "$D/assigned.bam"
  rm -f "$D/fc/Aligned.sortedByCoord.out.bam.featureCounts.bam"
  touch "$D/reads.done"
  log reads end
fi

if want count && [ ! -e "$D/count.done" ]; then
  need reads
  $TIME nice -n 15 "$B/umi_tools" count --per-gene --gene-tag=XT --assigned-status-tag=XS --method=directional \
      -I "$D/assigned.bam" -S "$D/umi_count.tsv.gz" -L "$D/umi_count.log" 2> "$D/count.time"
  touch "$D/count.done"
  log count end
fi

if want dedup && [ ! -e "$D/dedup.done" ]; then
  need star
  $TIME nice -n 15 "$B/umi_tools" dedup --method=directional \
      -I "$D/Aligned.sortedByCoord.out.bam" -S "$D/dedup.bam" -L "$D/dedup.log" 2> "$D/dedup.time"
  nice -n 15 "$B/featureCounts" -T "$LT" -s "$STRAND" -a "$GTF" -o "$D/fc_dedup.txt" "$D/dedup.bam" \
      > "$D/fc_dedup.log" 2>&1
  touch "$D/dedup.done"
  log dedup end
fi
