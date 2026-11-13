#!/usr/bin/env bash
# Dry run of the waiting and retry logic of nmax.sh and heavy.sh, with a stub in place of STAR.
# Nothing aligns. The lock folder, PAUSE file, gate marker and hold file are the test's own, in a
# folder of its own (one sub-folder a scenario, kept for inspection, nothing deleted). It takes
# about a minute and checks, one PASS or FAIL line each:
#   A the gate marker, a PAUSE file and a foreign lock each hold the chain; STAR runs under the lock
#     and the hold file; one failure of a run in each step is retried once, and a finished run is not
#     aligned again; the chain ends with "exact: 6 of 6"
#   B a run that fails twice ends the chain with its exit status, and the lock and hold file are freed
#   C the gate cap ends the wait; a first run that is not exact stops the chain; a foreign hold file stays
#   D a lock that never frees ends the chain with exit 75 and leaves the foreign lock alone
#   E the load gate keeps the lock closed (exit 75) and opens when the load is under the limit
#   F DRY_RUN=1 checks the inputs, and a missing FASTQ stops a chain before it starts
#   G a chain that is killed leaves no hold file once its aligner ends
# Usage: nmax_selftest.sh [test_dir]     the exit status is the number of FAIL lines
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=${1:-$(mktemp -d "${TMPDIR:-/tmp}/nmax-selftest.XXXXXX")}
mkdir -p "$T" || exit 2
BIN=$T/bin
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }
until_() { local i; for i in $(seq 1 "${2:-60}"); do eval "$1" && return 0; sleep 1; done; return 1; }
RUNS="SRR34827376 SRR34827390 SRR34827398 SRR34827382 SRR34827404"
DONE_F() { echo "$W/work/compare_nmax1000/DONE"; }

build() {   # a fresh world in $T/<name>: data root, work folder, environments with stubs, the real scripts
  W=$T/$1; export W
  mkdir -p "$BIN" "$W/plan" "$W/data/studies/GSE304256/fastq" "$W/data/studies/GSE304256/geo" "$W/work/star_index" \
    "$W/work/ref" "$W/locks" "$W/env/bin" "$W/env-star273a/bin" "$W/c7/chain_b" "$W/c7/gf" "$W/work/star_nmax1000/SRR34827388"
  cp "$HERE/nmax.sh" "$HERE/heavy.sh" "$HERE/runs.tsv" "$BIN/"
  : > "$W/calls.log"
  touch "$W/work/star_index/.complete" "$W/work/ref/genes.tsv" "$W/data/studies/GSE304256/geo/GSE304256_RAW.tar" \
        "$W/data/studies/GSE304256/samples.tsv" "$W/env-star273a/bin/STAR"
  local r
  for r in $RUNS; do
    echo x > "$W/data/studies/GSE304256/fastq/${r}_1.fastq.gz"; echo x > "$W/data/studies/GSE304256/fastq/${r}_2.fastq.gz"
  done
  echo x > "$W/work/star_nmax1000/SRR34827388/ReadsPerGene.out.tab"; echo x > "$W/work/star_nmax1000/SRR34827388/Log.final.out"
  ln -sf "$(command -v python3)" "$W/env/bin/python3"
  cat > "$W/env/bin/samtools" <<'STUB'
#!/usr/bin/env bash
case $1 in quickcheck) exit 0 ;; view) printf 'r1\t65\tc\t1\t255\t10M\t=\t1\t0\tACGT\tIIII\tNH:i:3\n' ;; esac
STUB
  chmod +x "$W/env/bin/samtools"
  cat > "$BIN/star.sh" <<'STUB'
#!/usr/bin/env bash
# stub of "star.sh align": the exit status of each real call comes from $W/plan/<run>, one line a call
D=$3; run=$(basename "$D"); mkdir -p "$D"; act=run; rc=0
if [ -s "$D/ReadsPerGene.out.tab" ] && [ -s "$D/Log.final.out" ]; then act=skip; fi
if [ $act = run ] && [ -s "$W/plan/$run" ]; then
  rc=$(head -1 "$W/plan/$run"); tail -n +2 "$W/plan/$run" > "$W/plan/$run.n"; mv "$W/plan/$run.n" "$W/plan/$run"
  [ "$rc" != 0 ] && act=fail
fi
echo "$run $(date +%s) act=$act hold=$([ -e "$HOLD_FILE" ] && echo yes || echo no) lock=$([ -d "$LOCKS/heavy" ] && echo yes || echo no)" >> "$W/calls.log"
[ $act = skip ] && exit 0
sleep "${STUB_SLEEP:-1}"
if [ $act = fail ]; then echo partial > "$D/Aligned.out.bam"; exit "$rc"; fi
echo x > "$D/ReadsPerGene.out.tab"; echo x > "$D/Log.final.out"; echo bam > "$D/Aligned.out.bam"
[ -e "$W/plan/$run.notexact" ] && touch "$D/NOT_EXACT"
exit 0
STUB
  cat > "$BIN/compare.py" <<'STUB'
import argparse, csv, os
ap = argparse.ArgumentParser()
for k in ("--tar", "--runs", "--samples", "--star-dir", "--genes", "--out"):
    ap.add_argument(k)
a = ap.parse_args()
rows = list(csv.DictReader(open(a.runs), delimiter="\t"))
ex = []
with open(os.path.join(a.out, "runs.tsv"), "w") as fh:
    fh.write("run\tgeo_sample\tsample\tgroup\ttime_point\tverdict\n")
    for r in rows:
        d = os.path.join(a.star_dir, r["run"])
        v = "not run" if not os.path.exists(os.path.join(d, "ReadsPerGene.out.tab")) else (
            "not exact" if os.path.exists(os.path.join(d, "NOT_EXACT")) else "exact")
        if v == "exact":
            ex.append(r["run"])
        fh.write("\t".join([r["run"], r["geo_sample"], r["sample"], r["group"], r["time_point"], v]) + "\n")
open(os.path.join(a.out, "exact_runs.txt"), "w").write("".join(x + "\n" for x in ex))
print("stub compare:", len(ex), "exact")
STUB
}

# The chain, in the background, with short waits; extra environment assignments as arguments.
chain() {
  ( env HOLD_FILE="$W/c7/chain_b/HOLD_DEDUP" LOCKS="$W/locks" WAIT_FOR="$W/c7/gf/GATE_DEDUP_DONE" POLL=1 WAIT_CAP=60 \
        HEAVY_POLL=1 HEAVY_LOAD_MAX=100000 HEAVY_WAIT=1 RETRY_PAUSE=1 LOCK_PAUSE=1 THREADS=2 NICE=15 "$@" \
        "$BASH" "$BIN/nmax.sh" "$W/data" "$W/work" "$W/env" 1000 $RUNS > "$W/chain.log" 2>&1
    echo $? > "$W/chain.rc" ) &
}
chain_pid() { sed -n 's/.*nmax.sh start: pid \([0-9]*\),.*/\1/p' "$W/chain.log" | head -1; }

echo "nmax_selftest.sh: bash $BASH_VERSION, test folder $T"

echo "== A gate marker, PAUSE file, foreign lock, hold file, one retry in each step"
build A
printf '104\n0\n' > "$W/plan/SRR34827376"; printf '104\n0\n' > "$W/plan/SRR34827382"
touch "$W/locks/PAUSE"; mkdir "$W/locks/heavy"; echo "foreign lane" > "$W/locks/heavy/owner"
chain
until_ 'grep -q "waiting for" "$W/chain.log"' 10; sleep 3
ok "A1 nothing starts while the gate marker is missing" '[ ! -s "$W/calls.log" ]'
touch "$W/c7/gf/GATE_DEDUP_DONE"; sleep 4
ok "A2 the marker is seen, but a PAUSE file and a foreign lock still hold the chain" 'grep -q "GATE_DEDUP_DONE exists" "$W/chain.log" && [ ! -s "$W/calls.log" ]'
rm -f "$W/locks/PAUSE"; sleep 4
ok "A3 without PAUSE the foreign lock still holds the chain" '[ ! -s "$W/calls.log" ] && [ -d "$W/locks/heavy" ]'
rm -f "$W/locks/heavy/owner"; rmdir "$W/locks/heavy"
until_ '[ -e "$(DONE_F)" ]' 90
ok "A4 DONE says exact: 6 of 6 runs" 'head -1 "$(DONE_F)" | grep -q "^exact: 6 of 6 runs with K=1000"'
ok "A5 DONE line 2 gives every verdict, the run of the first chain included" 'sed -n 2p "$(DONE_F)" | grep -q "SRR34827388:exact.*SRR34827404:exact"'
ok "A6 every run or failure of the stub held the lock and the hold file" '! grep -v "act=skip" "$W/calls.log" | grep -qv "hold=yes lock=yes"'
ok "A7 the first run failed once and was tried again once" '[ "$(grep -c "^SRR34827376 .*act=fail" "$W/calls.log")" = 1 ] && [ "$(grep -c "^SRR34827376 .*act=run" "$W/calls.log")" = 1 ]'
ok "A8 a later run failed once and was tried again once" '[ "$(grep -c "^SRR34827382 .*act=fail" "$W/calls.log")" = 1 ] && [ "$(grep -c "^SRR34827382 .*act=run" "$W/calls.log")" = 1 ]'
ok "A9 a run that finished before a retry was not aligned again" '[ "$(grep -c "^SRR34827390 .*act=run" "$W/calls.log")" = 1 ]'
ok "A10 the hold file and the lock are gone, exit 0" '[ ! -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ ! -d "$W/locks/heavy" ] && [ "$(cat "$W/chain.rc")" = 0 ]'
ok "A11 NH tables only from finished alignments, BAMs deleted" '[ -s "$W/work/compare_nmax1000/nh_SRR34827376.tsv" ] && [ -z "$(ls "$W"/work/star_nmax1000/*/Aligned.out.bam 2>/dev/null)" ]'

echo "== B a run that fails twice ends the chain"
build B; touch "$W/c7/gf/GATE_DEDUP_DONE"; printf '104\n104\n' > "$W/plan/SRR34827390"
chain; until_ '[ -e "$(DONE_F)" ]' 60; sleep 1
ok "B1 DONE says later runs failed rc 104" 'head -1 "$(DONE_F)" | grep -q "^later runs failed rc 104 (failed: SRR34827390 SRR34827390;"'
ok "B2 the chain exits 104" '[ "$(cat "$W/chain.rc")" = 104 ]'
ok "B3 the run was tried twice and no more, the later runs not at all" '[ "$(grep -c "^SRR34827390 " "$W/calls.log")" = 2 ] && ! grep -q "^SRR34827398 " "$W/calls.log"'
ok "B4 the hold file and the lock are gone" '[ ! -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ ! -d "$W/locks/heavy" ]'
ok "B5 no NH table from the truncated BAM of the failed run" '[ ! -e "$W/work/compare_nmax1000/nh_SRR34827390.tsv" ]'

echo "== C gate cap, first run not exact, foreign hold file"
build C; echo "someone else" > "$W/c7/chain_b/HOLD_DEDUP"; touch "$W/plan/SRR34827376.notexact"
chain WAIT_CAP=2; until_ '[ -e "$(DONE_F)" ]' 40
ok "C1 the cap ended the wait with a log line" 'grep -q "still missing after the cap" "$W/chain.log"'
ok "C2 DONE says the first run is not exact, the others not run" 'head -1 "$(DONE_F)" | grep -q "^SRR34827376 not exact with K=1000; others not run"'
ok "C3 no later run started" '! grep -q "^SRR34827390 " "$W/calls.log"'
ok "C4 a foreign hold file is left as it was" '[ "$(cat "$W/c7/chain_b/HOLD_DEDUP")" = "someone else" ]'

echo "== D a lock that never frees"
build D; touch "$W/c7/gf/GATE_DEDUP_DONE"; mkdir "$W/locks/heavy"
chain HEAVY_WAIT=0; until_ '[ -e "$(DONE_F)" ]' 40; sleep 1
ok "D1 DONE says first run failed rc 75, the chain exits 75" 'head -1 "$(DONE_F)" | grep -q "^first run failed rc 75" && [ "$(cat "$W/chain.rc")" = 75 ]'
ok "D2 nothing aligned, no hold file, the foreign lock stands" '[ ! -s "$W/calls.log" ] && [ ! -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ -d "$W/locks/heavy" ]'

echo "== E the load gate"
mkdir -p "$W/locks_e"
HEAVY_LOAD_MAX=1 "$BASH" "$BIN/heavy.sh" "$W/locks_e" t 0 true > /dev/null 2>&1; rc=$?
ok "E1 a load limit of 1 keeps the lock closed (exit 75) and takes no lock" '[ $rc = 75 ] && [ ! -d "$W/locks_e/heavy" ]'
HEAVY_LOAD_MAX=100000 "$BASH" "$BIN/heavy.sh" "$W/locks_e" t 0 true > /dev/null 2>&1; rc=$?
ok "E2 a limit above the load runs the step and frees the lock" '[ $rc = 0 ] && [ ! -d "$W/locks_e/heavy" ]'

echo "== F DRY_RUN"
build F
DRY_RUN=1 LOCKS="$W/locks" WAIT_FOR="$W/c7/gf/GATE_DEDUP_DONE" HOLD_FILE="$W/c7/chain_b/HOLD_DEDUP" \
  "$BASH" "$BIN/nmax.sh" "$W/data" "$W/work" "$W/env" 1000 $RUNS > "$W/dry.log" 2>&1; rc=$?
ok "F1 a dry run with every input present ends with exit 0 and starts nothing" '[ $rc = 0 ] && grep -q "^dry run ends" "$W/dry.log" && [ ! -s "$W/calls.log" ] && [ ! -e "$(DONE_F)" ]'
rm -f "$W/data/studies/GSE304256/fastq/SRR34827398_2.fastq.gz"
chain; until_ '[ -e "$(DONE_F)" ]' 20; sleep 1
ok "F2 a missing FASTQ stops the chain before it starts (DONE preflight failed, exit 2)" 'head -1 "$(DONE_F)" | grep -q "^preflight failed" && [ "$(cat "$W/chain.rc")" = 2 ] && [ ! -s "$W/calls.log" ]'

echo "== G a killed chain"
build G; touch "$W/c7/gf/GATE_DEDUP_DONE"
chain STUB_SLEEP=5; until_ '[ -e "$W/c7/chain_b/HOLD_DEDUP" ]' 20
ok "G1 the hold file stands while STAR aligns" '[ -e "$W/c7/chain_b/HOLD_DEDUP" ]'
kill "$(chain_pid)" 2>/dev/null; sleep 1
ok "G2 the killed chain leaves the hold file and the lock to the aligner that still runs" '[ -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ -d "$W/locks/heavy" ]'
until_ '[ ! -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ ! -d "$W/locks/heavy" ]' 20
ok "G3 the aligner removes the hold file and frees the lock when it ends" '[ ! -e "$W/c7/chain_b/HOLD_DEDUP" ] && [ ! -d "$W/locks/heavy" ]'

echo "$fails FAIL"
exit $fails
