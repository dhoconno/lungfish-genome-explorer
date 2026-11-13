#!/usr/bin/env bash
# Test relaunch_waiter.sh's decisions on a fake staging state and fake process trees, then its
# stop and relaunch path with a fake chain. Touches nothing outside <scratch_dir> and stops only
# the sleep trees it starts here.
# Usage: test_waiter.sh <scratch_dir>
set -uo pipefail
T=$1; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$T"; T=$(cd "$T" && pwd)
D=$T/data; Wk=$T/work; B=$T/bin
mkdir -p "$D/studies/_stage_sc/state/GSE155673.done" "$D/studies/_stage_sc/logs/GSE155673.lane" \
  "$D/studies/GSE155673/fastq/GSM4712899" "$D/locks" "$Wk/logs" "$B/old" "$B/new"
ST=$D/studies/_stage_sc/state; SL=$D/studies/_stage_sc/logs/GSE155673.lane
: > "$ST/GSE155673.dl.tsv"; : > "$D/MANIFEST.tsv"; : > "$Wk/logs/chain.log"
for r in $(awk -F'\t' 'NR > 1 {print $1}' "$HERE/runs.tsv"); do
  echo "x" > "$ST/GSE155673.done/$r"
  printf '%s\tGSM4712899\t1\tmd5\tyes\t1\tZ\n' "$r" >> "$ST/GSE155673.dl.tsv"
  for role in I1_index R1_barcodeUMI R2_cDNA; do
    f=$D/studies/GSE155673/fastq/GSM4712899/${r}_$role.fastq.gz; : > "$f"; printf '%s\tderived\n' "$f" >> "$D/MANIFEST.tsv"
  done
done
# Fake old chain: chain.sh -> run.sh -> child (sleep, a fake solo.sh, or a fake heavy.sh waiting)
cat > "$B/old/chain.sh" <<'EOF'
bash "$(dirname "$0")/run.sh" "$1"
echo "fake old chain exit $?"
EOF
cat > "$B/old/run.sh" <<'EOF'
case $1 in
  solo) bash "$(dirname "$0")/solo.sh" ;;
  heavy) bash "$(dirname "$0")/heavy.sh" locks REPRO-GSE155673 60 nice -n 15 bash solo.sh ;;
  *) sleep 600 ;;
esac
EOF
printf 'sleep 600\n' > "$B/old/solo.sh"; printf 'sleep 600\n' > "$B/old/heavy.sh"
cat > "$B/new/chain.sh" <<'EOF'
echo "fake new chain pid $$ args $* BAM=$BAM LOCKS=$LOCKS THREADS=$THREADS"
EOF
start_old() { nohup bash "$B/old/chain.sh" "$1" > "$T/old.$1.log" 2>&1 & OC=$!; sleep 1
  OR=$(pgrep -P "$OC" | head -1); }
stop_old() { local p; for p in $(pgrep -P "$OR") "$OR" "$OC"; do kill "$p" 2>/dev/null; done; sleep 1; }
run() { ST=$ST SLOG=$SL FQ=$D/studies/GSE155673/fastq MANIFEST=$D/MANIFEST.tsv CHAIN=$B/new/chain.sh \
  LOCKS=$D/locks WORKER_PAT="no-such-worker-$$" WAIT_INTERVAL=1 WAIT_MAX_HOURS=1 \
  bash "$HERE/relaunch_waiter.sh" "$D" "$Wk" "$T/env" "$OC" "$OR"; }
fails=0
check() { local want=$1 got; got=$(DRY_RUN=1 run | awk '/^decision/ {print $2}')
  if [ "$got" = "$want" ]; then echo "ok   $2: $got"; else echo "FAIL $2: want $want, got $got"; DRY_RUN=1 run; fails=$((fails + 1)); fi; }

start_old sleep
check relaunch "8 done, verified, no worker, nothing started"
lr=$(awk -F'\t' 'NR > 1 {print $1}' "$HERE/runs.tsv" | tail -1)
rm "$ST/GSE155673.done/$lr"; check staging "7 of 8 done"; echo x > "$ST/GSE155673.done/$lr"
sleep 600 & w=$!; echo $w > "$SL/SRR12404163.pid"; check staging "8 done, a worker alive"; kill $w; wait $w 2>/dev/null
grep -v SRR12404160_R2 "$D/MANIFEST.tsv" > "$T/m" && mv "$D/MANIFEST.tsv" "$T/m.full" && mv "$T/m" "$D/MANIFEST.tsv"
check unverified "a FASTQ without its ledger row"; mv "$T/m.full" "$D/MANIFEST.tsv"
grep -v '^SRR12404161' "$ST/GSE155673.dl.tsv" > "$T/d"; printf 'SRR12404161\tGSM4712899\t1\tmd5\tno\t1\tZ\n' >> "$T/d"
cp "$ST/GSE155673.dl.tsv" "$T/d.full"; mv "$T/d" "$ST/GSE155673.dl.tsv"; check unverified "an md5 row without yes"; mv "$T/d.full" "$ST/GSE155673.dl.tsv"
mkdir -p "$Wk/solo/GSM4712899"; check started "solo folder exists"; rmdir "$Wk/solo/GSM4712899" "$Wk/solo"
echo "lock taken 12:00:00 load 3 free 60%" >> "$Wk/logs/chain.log"; check started "chain.log has lock taken"; : > "$Wk/logs/chain.log"
mkdir "$D/locks/heavy"; echo "REPRO-GSE155673 2026-11-13 12:00:00 pid $OR" > "$D/locks/heavy/owner"; check started "heavy lock held by a pid of the tree"
echo "REPRO-OTHER 2026-11-13 12:00:00 pid $OR" > "$D/locks/heavy/owner"; check relaunch "heavy lock held by another lane"
rm "$D/locks/heavy/owner"; rmdir "$D/locks/heavy"
stop_old
start_old solo; check started "solo.sh process in the tree"; stop_old
start_old heavy; check relaunch "heavy.sh waiting for the lock (solo.sh only in its arguments)"
# The stop and relaunch path, on the heavy.sh tree
old="$OC $OR $(pgrep -P "$OR")"
run > "$T/waiter.log" 2>&1; rc=$?; sleep 2
cat "$T/waiter.log"
left=""; for p in $old; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
[ $rc = 0 ] && [ -z "$left" ] && grep -q 'fake new chain .*args .*inputs index align compare claims BAM=0' "$Wk/logs/chain.log" \
  && grep -q '^relaunched' "$Wk/logs/relaunch.state" \
  && echo "ok   stop and relaunch: old tree ($old) gone, new chain $(cat "$Wk/logs/relaunch.pid") logged" \
  || { echo "FAIL stop and relaunch: rc $rc, left$left"; cat "$Wk/logs/chain.log"; fails=$((fails + 1)); }
check gone "old chain gone"
echo "fails $fails"; exit $fails
