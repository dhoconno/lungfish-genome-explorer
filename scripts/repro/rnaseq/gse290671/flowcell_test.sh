#!/usr/bin/env bash
# Test whether a deposited GSE290671 column comes from one sequencing run
# (flowcell) of the SRA run's reads.
#
# Each SRA run of this study joins reads from several NextSeq flowcells. The
# FASTQ keeps the Illumina name as the second header word, while STAR keeps
# only the first (SRR...N), so the flowcell of a BAM record is found from the
# spot number N. This script finds each flowcell's spot range in read 1,
# splits the STAR BAM by those ranges, counts each part with count.R and
# compares each part with the deposited column.
#
# The split is one pass over the BAM. The part BAMs are deleted once their
# counts are written, unless KEEP_PARTS=1. LT sets the featureCounts threads
# (default 4).
#
# Usage:
#   flowcell_test.sh RUN SAMPLE FASTQ_R1 BAM OUTDIR GTF DEPOSIT ENV BIOC_ENV MODE
set -euo pipefail
RUN=$1; SAMPLE=$2; R1=$3; BAM=$4; OUT=$5; GTF=$6; DEP=$7; ENV=$8; BIOC=$9; MODE=${10}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

# Spot ranges per flowcell, in file order: flowcell first last.
gunzip -c "$R1" | awk 'NR%4==1 {split($2, a, ":"); fc = a[3]; n = (NR + 3) / 4;
  if (fc != cur) { if (cur != "") print cur, first, n - 1; cur = fc; first = n } }
  END { print cur, first, (NR) / 4 }' > "$OUT/flowcells.txt"
cat "$OUT/flowcells.txt"

# One pass: each record goes to the part whose spot range holds its spot
# number, and the header goes to every part.
# A flowcell may hold more than one range; its part is one BAM.
bams=()
for fc in $(awk '!seen[$1]++ {print $1}' "$OUT/flowcells.txt"); do
  mkdir -p "$OUT/$fc"
  bams+=("$OUT/$fc/Aligned.out.bam")
done
"$ENV/bin/samtools" view -@ 1 -h "$BAM" \
  | awk -F'\t' -v ranges="$(tr '\n' ';' < "$OUT/flowcells.txt")" -v out="$OUT" \
      -v st="$ENV/bin/samtools" '
    BEGIN { n = split(ranges, rr, ";"); k = 0
      for (i = 1; i <= n; i++) { if (rr[i] == "") continue; split(rr[i], p, " ")
        k++; lo[k] = p[2] + 0; hi[k] = p[3] + 0; fc[k] = p[1]
        cmd[p[1]] = st " view -b -o " out "/" p[1] "/Aligned.out.bam -" } }
    /^@/ { for (f in cmd) print | cmd[f]; next }
    { split($1, a, "."); s = a[2] + 0
      for (i = 1; i <= k; i++) if (s >= lo[i] && s <= hi[i]) { print | cmd[fc[i]]; break } }
    END { for (f in cmd) close(cmd[f]) }'

"$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/parts" "$MODE" "${LT:-4}" "${bams[@]}" > "$OUT/count.log" 2>&1
"$ENV/bin/python3" -I "$HERE/match_columns.py" "$DEP" "$OUT/parts.counts.tsv" 3 | tee "$OUT/columns.txt"

# Exact test of each part, and of the sum of every pair of parts, against
# the sample's deposited column.
"$ENV/bin/python3" -I - "$DEP" "$OUT/parts.counts.tsv" "$SAMPLE" <<'EOF' | tee "$OUT/exact.txt"
import csv, gzip, itertools, sys
dep_path, parts_path, sample = sys.argv[1:4]
with gzip.open(dep_path, "rt") as fh:
    rows = [[c.strip('"') for c in r] for r in csv.reader(fh, delimiter="\t")]
j = rows[0].index(sample)
dep = [int(r[j]) for r in rows[1:]]
with open(parts_path) as fh:
    prow = list(csv.reader(fh, delimiter="\t"))
names = prow[0][1:]
cols = {n: [int(float(r[k + 1])) for r in prow[1:]] for k, n in enumerate(names)}
combos = [(n,) for n in names] + list(itertools.combinations(names, 2)) + [tuple(names)]
for c in combos:
    v = [sum(cols[n][i] for n in c) for i in range(len(dep))]
    diff = sum(a != b for a, b in zip(v, dep))
    print("+".join(c), "genes_differ", diff, "sum", sum(v), "deposit_sum", sum(dep))
EOF

if [ "${KEEP_PARTS:-0}" != 1 ] && [ -s "$OUT/parts.counts.tsv" ] && [ -s "$OUT/exact.txt" ]; then
  for b in "${bams[@]}"; do rm -f "$b"; done
fi
