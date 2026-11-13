#!/usr/bin/env bash
# The queued rerun of C6's K=1000 chain (ADJ-BULK-4, C6 Q1 and item 1). The first chain ended with
# SRR34827388 exact and SRR34827376 failed (rc 104, a gunzip pipe error); this runs the other five.
#
# Usage: nmax_rerun.sh <data_root> <work_dir> <env_prefix> <c7_work_dir>
#   c7_work_dir  gse290671's work folder: gf/GATE_DEDUP_DONE is the marker to wait for, and
#                chain_b/HOLD_DEDUP the hold file its dedup_count.sh honors while STAR aligns here.
# It waits for the marker (12 hours at most), takes the heavy lock (LOCKS, default <data_root>/locks)
# under the PAUSE, memory and load gates, with 8 threads at nice 15, and retries a failed run once.
# Run it as: nohup bash nmax_rerun.sh ... > <log> 2>&1 &      (DRY_RUN=1 checks the inputs and stops)
set -uo pipefail
[ $# -eq 4 ] || { sed -n '2,10p' "$0"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
export LOCKS=${LOCKS:-$1/locks} THREADS=${THREADS:-8} NICE=${NICE:-15}
export WAIT_FOR=${WAIT_FOR:-$4/gf/GATE_DEDUP_DONE} HOLD_FILE=${HOLD_FILE:-$4/chain_b/HOLD_DEDUP}
exec "$BASH" "$HERE/nmax.sh" "$1" "$2" "$3" 1000 SRR34827376 SRR34827390 SRR34827398 SRR34827382 SRR34827404
