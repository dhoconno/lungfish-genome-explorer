#!/usr/bin/env bash
# STAR alignment of one GSE225770 sample, rerunnable. It is the heavy step of the per-sample loop
# in run.sh, which wraps it in heavy.sh so that it runs only while the lane holds the lock.
#   - A sample whose <name>.Log.final.out exists and whose two BAMs are not empty is skipped.
#   - A partial folder from a stopped run is removed first, so STAR starts clean.
#   - It stops with exit 75 (rerun later) when a PAUSE file sits beside the lock folder.
# Usage: align.sh <star_index> <gtf> <name> <r1> <r2> <out_dir> <star_bin> <threads> [locks_dir]
set -euo pipefail
IDX=$1; GTF=$2; NAME=$3; R1=$4; R2=$5; OUT=$6; STARBIN=$7; T=$8; LOCKS=${9:--}
HERE=$(cd "$(dirname "$0")" && pwd)

done_ok() {
  [ -s "$OUT/$NAME.Log.final.out" ] && [ -s "$OUT/$NAME.Aligned.out.bam" ] \
    && [ -s "$OUT/$NAME.Aligned.toTranscriptome.out.bam" ]
}
if done_ok; then echo "$NAME already aligned"; exit 0; fi
if [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; then echo "PAUSE file found before $NAME"; exit 75; fi
for f in "$R1" "$R2"; do [ -s "$f" ] || { echo "missing reads $f" >&2; exit 2; }; done
# A stopped run leaves _STARtmp and empty BAMs; STAR refuses to reuse its temporary folder.
case $OUT in */"$NAME") ;; *) echo "out_dir must end in /$NAME" >&2; exit 2 ;; esac
if [ -d "$OUT" ]; then rm -rf "$OUT"; fi
echo "$(date '+%H:%M:%S') aligning $NAME with $T threads"
bash "$HERE/star.sh" align "$IDX" "$GTF" "$NAME" "$R1" "$R2" "$OUT" "$STARBIN" "$T"
# The temporary folder and the copy of the junction-inserted genome are not outputs. The small
# pass-1 folder stays, since it holds the first pass's junctions and log.
rm -rf "$OUT/$NAME._STARtmp" "$OUT/$NAME._STARgenome"
done_ok || { echo "$NAME: STAR ended without its outputs" >&2; exit 1; }
grep -E "Number of input reads|Uniquely mapped reads %|% of reads mapped to multiple loci" "$OUT/$NAME.Log.final.out"
echo "$(date '+%H:%M:%S') $NAME aligned"
