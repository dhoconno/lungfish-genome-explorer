#!/usr/bin/env bash
# Toy test of how a STAR build files the reads "mapped to too many loci" in the N_ rows of
# ReadsPerGene.out.tab. On the six C6 runs every gene row equals the deposit, and the deposit's
# N_multimapping exceeds ours by exactly our Log.final.out count of reads mapped to too many
# loci, while its N_unmapped is short by the same number. This script asks which row each local
# STAR files those reads in, on a genome small enough to be a light step.
#
# Usage: toy_nrows.sh <work_dir> <python_env> <star_env> [<star_env> ...]
# Each star_env is a folder with bin/STAR. The toy genome is 400 kb of random sequence with
#   - a spliced gene GU (two exons, a GT-AG intron), unique: 200 pairs
#   - a 400-base segment copied 12 times, gene GR12 on copy 1: 50 pairs (12 loci, over the
#     default --outFilterMultimapNmax of 10)
#   - a 400-base segment copied 3 times, gene GR3 on copy 1: 30 pairs (3 loci)
#   - 20 pairs of random sequence that maps nowhere
# Every build runs star.sh's own alignment options. The first build runs again with
# --outFilterMultimapNmax 20, the knob that moves the 12-locus pairs by a flag.
set -euo pipefail
W=$1; PYENV=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
NICE="nice -n ${NICE:-15}"
rm -rf "$W"; mkdir -p "$W"
$NICE "$PYENV/bin/python3" -I - "$W" <<'EOF'
import gzip, random, sys
w = sys.argv[1]
rng = random.Random(20261113)
def rs(n): return "".join(rng.choice("ACGT") for _ in range(n))
def rc(s): return s.translate(str.maketrans("ACGT", "TGCA"))[::-1]
g = list(rs(400_000))
r12, r3 = rs(400), rs(400)
p12 = [20_000 + 20_000 * i for i in range(12)]       # 20,000 .. 240,000
p3 = [260_000, 290_000, 320_000]
for p in p12: g[p:p + 400] = r12
for p in p3: g[p:p + 400] = r3
e1, e2 = (340_000, 340_500), (341_500, 342_000)        # 0-based half-open
g[e1[1]:e1[1] + 2] = "GT"; g[e2[0] - 2:e2[0]] = "AG"
g = "".join(g)
open(f"{w}/genome.fa", "w").write(">chr1\n" + "\n".join(g[i:i + 60] for i in range(0, len(g), 60)) + "\n")
gtf = []
def exon(gene, s, e):   # 1-based closed
    a = f'gene_id "{gene}"; transcript_id "{gene}.t1"; gene_name "{gene}";'
    gtf.append(f"chr1\ttoy\texon\t{s}\t{e}\t.\t+\t.\t{a}")
exon("GU", e1[0] + 1, e1[1]); exon("GU", e2[0] + 1, e2[1])
exon("GR12", p12[0] + 1, p12[0] + 400); exon("GR3", p3[0] + 1, p3[0] + 400)
open(f"{w}/genes.gtf", "w").write("\n".join(gtf) + "\n")
tx = g[e1[0]:e1[1]] + g[e2[0]:e2[1]]
L, F = 60, 200
pairs = []
for src, n in ((tx, 200), (r12, 50), (r3, 30)):
    for _ in range(n):
        s = rng.randrange(0, len(src) - F + 1); f = src[s:s + F]
        pairs.append((f[:L], rc(f)[:L]))
for _ in range(20): pairs.append((rs(L), rs(L)))
with gzip.open(f"{w}/r1.fq.gz", "wt") as a, gzip.open(f"{w}/r2.fq.gz", "wt") as b:
    for i, (x, y) in enumerate(pairs):
        a.write(f"@p{i}/1\n{x}\n+\n{'I' * L}\n"); b.write(f"@p{i}/2\n{y}\n+\n{'I' * L}\n")
EOF
row() { awk -v k="$2" '$1==k{print $2}' "$1/ReadsPerGene.out.tab"; }
log() { awk -F'|' -v k="$2" 'index($1,k){gsub(/[ \t]/,"",$2); print $2}' "$1/Log.final.out"; }
printf 'build\tflags\tversion\tN_unmapped\tN_multimapping\tN_noFeature\tGU\tGR3\tGR12\tlog_multiple\tlog_too_many\tlog_short\tlog_other\n' > "$W/result.tsv"
report() {  # dir label flags
  local d=$1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" \
    "$(row "$d" N_unmapped)" "$(row "$d" N_multimapping)" "$(row "$d" N_noFeature)" \
    "$(row "$d" GU)" "$(row "$d" GR3)" "$(row "$d" GR12)" \
    "$(log "$d" 'Number of reads mapped to multiple loci')" "$(log "$d" 'Number of reads mapped to too many loci')" \
    "$(log "$d" 'Number of reads unmapped: too short')" "$(log "$d" 'Number of reads unmapped: other')" >> "$W/result.tsv"
}
first=1
for SE in "$@"; do
  v=$("$SE/bin/STAR" --version); tag=b$v
  STAR_INDEX_EXTRA="--genomeSAindexNbases 8" $NICE bash "$HERE/star.sh" index "$W/genome.fa" "$W/genes.gtf" \
    "$W/idx_$tag" "$SE" 2 59 > "$W/idx_$tag.log" 2>&1
  $NICE bash "$HERE/star.sh" align "$W/idx_$tag" "$W/aln_$tag" "$SE" 2 "$W/r1.fq.gz" "$W/r2.fq.gz" > "$W/aln_$tag.log" 2>&1
  report "$W/aln_$tag" "$tag" default "$v"
  if [ $first = 1 ]; then
    STAR_ALIGN_EXTRA="--outFilterMultimapNmax 20" $NICE bash "$HERE/star.sh" align "$W/idx_$tag" "$W/aln_${tag}_nmax20" \
      "$SE" 2 "$W/r1.fq.gz" "$W/r2.fq.gz" > "$W/aln_${tag}_nmax20.log" 2>&1
    report "$W/aln_${tag}_nmax20" "$tag" "--outFilterMultimapNmax 20" "$v"
    first=0
  fi
done
column -t -s $'\t' "$W/result.tsv"
