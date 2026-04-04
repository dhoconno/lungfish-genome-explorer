#!/usr/bin/env bash
# benchmark-vsp2-lib.sh — shared helper library for VSP2 pipeline benchmarks
# Source this file; do not execute directly.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/benchmark-vsp2-lib.sh"

# ---------------------------------------------------------------------------
# Repo root (resolved relative to this file, not the caller)
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Bundled tool paths
# ---------------------------------------------------------------------------
TOOLS_DIR="${REPO_ROOT}/Sources/LungfishWorkflow/Resources/Tools"

FASTP="${TOOLS_DIR}/fastp"
PIGZ="${TOOLS_DIR}/pigz"
SEQKIT="${TOOLS_DIR}/seqkit"

BBTOOLS_DIR="${TOOLS_DIR}/bbtools"
CLUMPIFY="${BBTOOLS_DIR}/clumpify.sh"
BBMERGE="${BBTOOLS_DIR}/bbmerge.sh"
REFORMAT="${BBTOOLS_DIR}/reformat.sh"
BBDUK="${BBTOOLS_DIR}/bbduk.sh"

SCRUBBER_DIR="${TOOLS_DIR}/scrubber"
SCRUB_SH="${SCRUBBER_DIR}/scripts/scrub.sh"

JRE_BIN="${TOOLS_DIR}/jre/bin"

# ---------------------------------------------------------------------------
# Databases
# ---------------------------------------------------------------------------
SCRUBBER_DB="${REPO_ROOT}/Sources/LungfishWorkflow/Resources/Databases/human-scrubber/human_filter.db.20250916v2"
DEACON_DB="${HOME}/Library/Application Support/Lungfish/databases/deacon/panhuman-1.k31w15.idx"

# ---------------------------------------------------------------------------
# Resource constraints
# ---------------------------------------------------------------------------
# Prefer performance cores; fall back to half the logical core count.
THREADS="${THREADS:-}"
if [[ -z "$THREADS" ]]; then
    perf_cores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)
    if [[ -n "$perf_cores" && "$perf_cores" -gt 0 ]]; then
        THREADS="$perf_cores"
    else
        logical=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)
        THREADS=$(( logical / 2 ))
        [[ "$THREADS" -lt 1 ]] && THREADS=1
    fi
fi
export THREADS

HEAP_GB=9

# ---------------------------------------------------------------------------
# Test data
# ---------------------------------------------------------------------------
R1="${BENCH_R1:-/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R1_001.fastq.gz}"
R2="${BENCH_R2:-/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R2_001.fastq.gz}"

# ---------------------------------------------------------------------------
# BBTools environment
# ---------------------------------------------------------------------------
# Call this before any BBTools shell script invocation.
bbtools_env() {
    export PATH="${JRE_BIN}:${BBTOOLS_DIR}:${PATH}"
    export JAVA_HOME="${TOOLS_DIR}/jre"
    export BBMAP_JAVA="${TOOLS_DIR}/jre/bin/java"
}

# ---------------------------------------------------------------------------
# Timed execution
# ---------------------------------------------------------------------------
# run_timed <timing_file> <command> [args...]
# Runs <command> with /usr/bin/time -l; stderr (including timing output) goes
# to <timing_file>.  The command's own stderr is interleaved into the same file.
run_timed() {
    local timing_file="$1"
    shift
    /usr/bin/time -l "$@" 2>"$timing_file"
}

# ---------------------------------------------------------------------------
# parse_timing <timing_file>
# Prints: wall_sec peak_rss_mb cpu_sec
#
# macOS /usr/bin/time -l output (first two relevant lines):
#   "      0.12 real         0.08 user         0.01 sys"
#   "    12345678  maximum resident set size"
# ---------------------------------------------------------------------------
parse_timing() {
    local timing_file="$1"
    local wall=0 user_cpu=0 sys_cpu=0 rss_bytes=0 rss_mb=0 cpu=0

    # Parse real/user/sys from the first timing line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]+real[[:space:]]+([0-9]+\.[0-9]+)[[:space:]]+user[[:space:]]+([0-9]+\.[0-9]+)[[:space:]]+sys ]]; then
            wall="${BASH_REMATCH[1]}"
            user_cpu="${BASH_REMATCH[2]}"
            sys_cpu="${BASH_REMATCH[3]}"
        elif [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+maximum[[:space:]]+resident[[:space:]]+set[[:space:]]+size ]]; then
            rss_bytes="${BASH_REMATCH[1]}"
        fi
    done < "$timing_file"

    # macOS reports RSS in bytes; convert to MB
    rss_mb=$(awk "BEGIN { printf \"%.1f\", ${rss_bytes} / 1048576 }")
    cpu=$(awk "BEGIN { printf \"%.2f\", ${user_cpu} + ${sys_cpu} }")

    echo "${wall} ${rss_mb} ${cpu}"
}

# ---------------------------------------------------------------------------
# count_reads <file>
# Prints: num_reads num_bases
# ---------------------------------------------------------------------------
count_reads() {
    local file="$1"
    local stats
    stats=$("$SEQKIT" stats --tabular "$file" 2>/dev/null | tail -n1)
    local num_reads num_bases
    num_reads=$(echo "$stats" | awk '{print $4}')
    num_bases=$(echo "$stats" | awk '{print $5}')
    echo "${num_reads} ${num_bases}"
}

# ---------------------------------------------------------------------------
# count_reads_paired <r1> [r2]
# Prints: total_reads (sum of R1 + R2, or just R1 if no R2 given)
# ---------------------------------------------------------------------------
count_reads_paired() {
    local r1="$1"
    local r2="${2:-}"

    local reads1 bases1 reads2 total
    read -r reads1 bases1 < <(count_reads "$r1")
    if [[ -n "$r2" ]]; then
        read -r reads2 _ < <(count_reads "$r2")
        total=$(( reads1 + reads2 ))
    else
        total="$reads1"
    fi
    echo "$total"
}

# ---------------------------------------------------------------------------
# write_result_header <outfile>
# ---------------------------------------------------------------------------
write_result_header() {
    local outfile="$1"
    printf "tool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\treads_out\tpct_change\n" > "$outfile"
}

# ---------------------------------------------------------------------------
# write_result_row <outfile> <tool> <wall> <rss> <cpu> <reads_in> <reads_out>
# pct_change = (reads_out - reads_in) / reads_in * 100
# ---------------------------------------------------------------------------
write_result_row() {
    local outfile="$1" tool="$2" wall="$3" rss="$4" cpu="$5"
    local reads_in="$6" reads_out="$7"
    local pct_change
    pct_change=$(awk "BEGIN { if (${reads_in}+0 > 0) printf \"%.2f\", (${reads_out} - ${reads_in}) / ${reads_in} * 100; else print \"N/A\" }")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$tool" "$wall" "$rss" "$cpu" "$reads_in" "$reads_out" "$pct_change" \
        >> "$outfile"
}

# ---------------------------------------------------------------------------
# ensure_workdir <subdir>
# Creates benchmarks/vsp2-YYYYMMDD/<subdir>/ under repo root, prints path.
# ---------------------------------------------------------------------------
ensure_workdir() {
    local subdir="$1"
    local date_tag
    date_tag=$(date +%Y%m%d)
    local workdir="${REPO_ROOT}/benchmarks/vsp2-${date_tag}/${subdir}"
    mkdir -p "$workdir"
    echo "$workdir"
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info() {
    printf "[%s] INFO  %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_done() {
    printf "[%s] DONE  %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}
