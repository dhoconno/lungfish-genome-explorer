# VSP2 Pipeline Optimization Benchmarking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Benchmark three alternative tools against the current VSP2 FASTQ processing pipeline and determine the fastest combination that fits within a 16GB memory envelope.

**Architecture:** A standalone bash benchmarking script (`scripts/benchmark-vsp2.sh`) with subcommands for setup, individual benchmarks, end-to-end comparison, and report generation. Uses bundled tools from the project's `Sources/LungfishWorkflow/Resources/Tools/` directory. Deacon installed via conda into an isolated environment.

**Tech Stack:** Bash, bundled CLI tools (fastp, clumpify.sh, bbmerge.sh, scrub.sh, seqkit, pigz), conda (miniforge3), deacon

---

## File Structure

| File | Responsibility |
|------|---------------|
| `scripts/benchmark-vsp2.sh` | Main benchmark driver script with subcommands |
| `scripts/benchmark-vsp2-lib.sh` | Shared helper functions (timing, read counting, TSV writing) |

Output (not committed, gitignored):
```
benchmarks/vsp2-YYYYMMDD/    # Results directory tree
```

---

### Task 1: Create the shared helper library

**Files:**
- Create: `scripts/benchmark-vsp2-lib.sh`

- [ ] **Step 1: Create `scripts/benchmark-vsp2-lib.sh` with path resolution, timing, and read-counting helpers**

```bash
#!/usr/bin/env bash
# benchmark-vsp2-lib.sh — shared helpers for VSP2 benchmarking
set -euo pipefail

# ── Path resolution ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Tools"

FASTP="$TOOLS/fastp"
CLUMPIFY="$TOOLS/bbtools/clumpify.sh"
BBMERGE="$TOOLS/bbtools/bbmerge.sh"
REFORMAT="$TOOLS/bbtools/reformat.sh"
SCRUB_SH="$TOOLS/scrubber/scripts/scrub.sh"
PIGZ="$TOOLS/pigz"
SEQKIT="$TOOLS/seqkit"
BBDUK="$TOOLS/bbtools/bbduk.sh"

SCRUBBER_DB="$PROJECT_ROOT/Sources/LungfishWorkflow/Resources/Databases/human-scrubber/human_filter.db.20250916v2"
DEACON_DB="$HOME/Library/Application Support/Lungfish/databases/deacon/panhuman-1.k31w15.idx"

# JRE for BBTools
JRE_BIN="$TOOLS/jre/bin"
JAVA_HOME_DIR="$TOOLS/jre"

# ── Resource constraints ─────────────────────────────────────────────
THREADS="${BENCH_THREADS:-$(sysctl -n hw.performancecores 2>/dev/null || echo $(( $(sysctl -n hw.ncpu) / 2 )))}"
HEAP_GB=9  # Java heap for BBTools on 16GB target

# ── Test data (override via env) ─────────────────────────────────────
R1="${BENCH_R1:-/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R1_001.fastq.gz}"
R2="${BENCH_R2:-/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R2_001.fastq.gz}"

# ── BBTools environment ──────────────────────────────────────────────
bbtools_env() {
    export PATH="$TOOLS:$JRE_BIN:$PATH"
    export JAVA_HOME="$JAVA_HOME_DIR"
    export BBMAP_JAVA="$JRE_BIN/java"
}

# ── Timing wrapper ───────────────────────────────────────────────────
# Usage: run_timed <output_timing_file> <command> [args...]
# Captures wall time, peak RSS, and user+system CPU time.
run_timed() {
    local timing_file="$1"; shift
    /usr/bin/time -l "$@" 2> "$timing_file"
}

# ── Parse /usr/bin/time -l output (macOS format) ────────────────────
# Returns: wall_sec peak_rss_mb cpu_sec
parse_timing() {
    local timing_file="$1"
    local wall_sec peak_rss_bytes user_sec sys_sec

    # macOS /usr/bin/time -l format:
    #   N.NN real   N.NN user   N.NN sys
    #   ... maximum resident set size ...
    wall_sec=$(awk '/real/ {print $1; exit}' "$timing_file")
    user_sec=$(awk '/user/ {print $1; exit}' "$timing_file")
    sys_sec=$(awk '/sys/ {print $1; exit}' "$timing_file")
    peak_rss_bytes=$(awk '/maximum resident set size/ {print $1; exit}' "$timing_file")

    local peak_rss_mb=$(( peak_rss_bytes / 1048576 ))
    local cpu_sec
    cpu_sec=$(awk "BEGIN {printf \"%.2f\", $user_sec + $sys_sec}")

    echo "$wall_sec $peak_rss_mb $cpu_sec"
}

# ── Read counting via seqkit ─────────────────────────────────────────
# Returns: num_reads  num_bases
count_reads() {
    local fq="$1"
    "$SEQKIT" stats --tabular "$fq" 2>/dev/null | tail -1 | awk -F'\t' '{print $4, $5}'
}

# Count reads in paired files (sum of R1 + R2, or single file)
count_reads_paired() {
    local r1="$1"
    local r2="${2:-}"
    local n1 n2
    n1=$("$SEQKIT" stats --tabular "$r1" 2>/dev/null | tail -1 | awk -F'\t' '{print $4}')
    if [[ -n "$r2" ]]; then
        n2=$("$SEQKIT" stats --tabular "$r2" 2>/dev/null | tail -1 | awk -F'\t' '{print $4}')
    else
        n2=0
    fi
    echo $(( n1 + n2 ))
}

# ── TSV helpers ──────────────────────────────────────────────────────
write_result_header() {
    local outfile="$1"
    echo -e "tool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\treads_out\tpct_change" > "$outfile"
}

write_result_row() {
    local outfile="$1" tool="$2" wall="$3" rss="$4" cpu="$5" reads_in="$6" reads_out="$7"
    local pct
    pct=$(awk "BEGIN {printf \"%.2f\", ($reads_in - $reads_out) / $reads_in * 100}")
    echo -e "${tool}\t${wall}\t${rss}\t${cpu}\t${reads_in}\t${reads_out}\t${pct}" >> "$outfile"
}

# ── Work directory ───────────────────────────────────────────────────
ensure_workdir() {
    local subdir="$1"
    local dir="$PROJECT_ROOT/benchmarks/vsp2-$(date +%Y%m%d)/$subdir"
    mkdir -p "$dir"
    echo "$dir"
}

log_info() {
    echo "[$(date +%H:%M:%S)] $*"
}

log_done() {
    echo "[$(date +%H:%M:%S)] ✓ $*"
}
```

- [ ] **Step 2: Verify the helper library sources without error**

Run:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
bash -n scripts/benchmark-vsp2-lib.sh
echo $?
```

Expected: `0` (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2-lib.sh
git commit -m "feat: add shared helper library for VSP2 benchmarking"
```

---

### Task 2: Create the setup subcommand (install deacon + download index)

**Files:**
- Create: `scripts/benchmark-vsp2.sh`

This task creates the main script with the `setup` subcommand. Subsequent tasks add more subcommands to this file.

- [ ] **Step 1: Create `scripts/benchmark-vsp2.sh` with setup subcommand**

```bash
#!/usr/bin/env bash
# benchmark-vsp2.sh — VSP2 pipeline optimization benchmarks
#
# Usage:
#   ./scripts/benchmark-vsp2.sh setup   — install deacon, download panhuman-1 index
#   ./scripts/benchmark-vsp2.sh dedup   — B1: clumpify vs fastp --dedup
#   ./scripts/benchmark-vsp2.sh scrub   — B2: STAT vs deacon
#   ./scripts/benchmark-vsp2.sh merge   — B3: bbmerge vs fastp --merge
#   ./scripts/benchmark-vsp2.sh e2e     — full pipeline comparison
#   ./scripts/benchmark-vsp2.sh report  — print summary table
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/benchmark-vsp2-lib.sh"

CONDA="$HOME/miniforge3/bin/conda"
DEACON_ENV="deacon-bench"

# ── setup ────────────────────────────────────────────────────────────
cmd_setup() {
    log_info "Setting up benchmarking environment..."

    # 1. Create conda env with deacon if it doesn't exist
    if "$CONDA" env list 2>/dev/null | grep -q "$DEACON_ENV"; then
        log_info "Conda environment '$DEACON_ENV' already exists"
    else
        log_info "Creating conda environment '$DEACON_ENV' with deacon..."
        "$CONDA" create -n "$DEACON_ENV" -c bioconda -c conda-forge deacon -y
    fi

    # Get the deacon binary path
    local deacon_bin
    deacon_bin="$("$CONDA" run -n "$DEACON_ENV" which deacon)"
    log_info "Deacon binary: $deacon_bin"
    "$CONDA" run -n "$DEACON_ENV" deacon --version

    # 2. Download panhuman-1 index if not present
    local db_dir="$HOME/Library/Application Support/Lungfish/databases/deacon"
    local idx_file="$db_dir/panhuman-1.k31w15.idx"

    if [[ -f "$idx_file" ]]; then
        log_info "Deacon index already exists at: $idx_file"
    else
        log_info "Downloading panhuman-1 index (3.3 GB)..."
        mkdir -p "$db_dir"
        "$CONDA" run -n "$DEACON_ENV" deacon index fetch panhuman-1
        # deacon index fetch downloads to current dir or a default location;
        # find and move to our db dir
        local fetched
        fetched=$(find "$HOME" -maxdepth 5 -name "panhuman-1.k31w15.idx" -not -path "$db_dir/*" 2>/dev/null | head -1)
        if [[ -n "$fetched" && ! -f "$idx_file" ]]; then
            mv "$fetched" "$idx_file"
            log_info "Moved index to: $idx_file"
        elif [[ -f "$idx_file" ]]; then
            log_info "Index already at: $idx_file"
        else
            log_info "WARNING: Could not locate downloaded index. Trying direct download..."
            curl -L -o "$idx_file" \
                "https://objectstorage.uk-london-1.oraclecloud.com/n/lrbvkel2wjot/b/human-genome-bucket/o/deacon/3/panhuman-1.k31w15.idx"
        fi
    fi

    # 3. Write manifest.json for DatabaseRegistry compatibility
    local manifest="$db_dir/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        cat > "$manifest" <<'MANIFEST'
{
  "id": "deacon",
  "displayName": "Deacon Human Pangenome Index",
  "tool": "deacon",
  "version": "panhuman-1",
  "filename": "panhuman-1.k31w15.idx",
  "description": "Minimizer index for human read depletion. Human pangenome plus bacterial and viral sequences. k=31, w=15, ~410M minimizers.",
  "sourceUrl": "https://github.com/bede/deacon"
}
MANIFEST
        log_info "Wrote manifest.json"
    fi

    # 4. Verify test data exists
    if [[ ! -f "$R1" ]]; then
        echo "ERROR: Test R1 not found: $R1" >&2; exit 1
    fi
    if [[ ! -f "$R2" ]]; then
        echo "ERROR: Test R2 not found: $R2" >&2; exit 1
    fi
    log_info "Test data R1: $R1 ($(du -h "$R1" | cut -f1))"
    log_info "Test data R2: $R2 ($(du -h "$R2" | cut -f1))"

    # 5. Verify all bundled tools
    local tools_ok=true
    for tool in "$FASTP" "$CLUMPIFY" "$BBMERGE" "$SCRUB_SH" "$PIGZ" "$SEQKIT" "$REFORMAT"; do
        if [[ ! -f "$tool" ]]; then
            echo "ERROR: Tool not found: $tool" >&2
            tools_ok=false
        fi
    done
    if [[ "$tools_ok" != true ]]; then exit 1; fi

    log_info "Threads: $THREADS"
    log_info "Java heap: ${HEAP_GB}g"
    log_done "Setup complete"
}

# ── deacon helper (runs deacon via conda env) ────────────────────────
run_deacon() {
    "$CONDA" run --no-banner -n "$DEACON_ENV" deacon "$@"
}

# ── Subcommand dispatch ──────────────────────────────────────────────
case "${1:-help}" in
    setup)  cmd_setup ;;
    dedup)  cmd_dedup ;;
    scrub)  cmd_scrub ;;
    merge)  cmd_merge ;;
    e2e)    cmd_e2e ;;
    report) cmd_report ;;
    help|*)
        echo "Usage: $0 {setup|dedup|scrub|merge|e2e|report}"
        echo ""
        echo "  setup   Install deacon, download panhuman-1 index, verify tools"
        echo "  dedup   B1: clumpify.sh vs fastp --dedup"
        echo "  scrub   B2: sra-human-scrubber vs deacon"
        echo "  merge   B3: bbmerge.sh vs fastp --merge"
        echo "  e2e     Full pipeline: current vs optimized"
        echo "  report  Print summary of all results"
        ;;
esac
```

- [ ] **Step 2: Make the script executable and verify syntax**

Run:
```bash
cd /Users/dho/Documents/lungfish-genome-explorer
chmod +x scripts/benchmark-vsp2.sh
bash -n scripts/benchmark-vsp2.sh
echo $?
```

Expected: The script will fail syntax check because `cmd_dedup`, `cmd_scrub`, etc. are not yet defined. That's expected — they'll be added in subsequent tasks. Verify it prints the help text:

```bash
bash scripts/benchmark-vsp2.sh help
```

Expected: Usage text printed.

- [ ] **Step 3: Add `benchmarks/` to .gitignore if not already present**

Check and add:
```bash
grep -q '^benchmarks/' .gitignore || echo 'benchmarks/' >> .gitignore
```

- [ ] **Step 4: Commit**

```bash
git add scripts/benchmark-vsp2.sh .gitignore
git commit -m "feat: add benchmark-vsp2.sh with setup subcommand and help"
```

---

### Task 3: Implement the dedup benchmark (B1: clumpify vs fastp --dedup)

**Files:**
- Modify: `scripts/benchmark-vsp2.sh`

- [ ] **Step 1: Add `cmd_dedup` function to `scripts/benchmark-vsp2.sh` (insert before the subcommand dispatch `case` block)**

```bash
# ── B1: dedup ────────────────────────────────────────────────────────
cmd_dedup() {
    log_info "=== B1: Deduplication — clumpify.sh vs fastp --dedup ==="
    local workdir
    workdir=$(ensure_workdir "B1-dedup")

    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads: $reads_in"

    # ── Clumpify (run 1: warm-up, run 2: timed) ─────────────────────
    local clump_dir="$workdir/clumpify"
    mkdir -p "$clump_dir"

    log_info "Running clumpify.sh (dedup)..."
    bbtools_env

    for run in 1 2; do
        log_info "  clumpify run $run/2..."
        run_timed "$clump_dir/timing_run${run}.txt" \
            "$CLUMPIFY" \
            "in=$R1" "in2=$R2" \
            "out=$clump_dir/dedup.R1.fq.gz" "out2=$clump_dir/dedup.R2.fq.gz" \
            "dedupe=t" "subs=0" \
            "reorder" "groups=auto" \
            "pigz=t" "zl=4" \
            "-Xmx${HEAP_GB}g" \
            "threads=$THREADS" \
            "ow=t"
    done
    cp "$clump_dir/timing_run2.txt" "$clump_dir/timing.txt"

    local clump_reads_out
    clump_reads_out=$(count_reads_paired "$clump_dir/dedup.R1.fq.gz" "$clump_dir/dedup.R2.fq.gz")
    log_done "Clumpify: $clump_reads_out reads out"

    # ── fastp --dedup (run 1: warm-up, run 2: timed) ────────────────
    local fastp_dir="$workdir/fastp"
    mkdir -p "$fastp_dir"

    log_info "Running fastp --dedup..."
    for run in 1 2; do
        log_info "  fastp run $run/2..."
        run_timed "$fastp_dir/timing_run${run}.txt" \
            "$FASTP" \
            -i "$R1" -I "$R2" \
            -o "$fastp_dir/dedup.R1.fq.gz" -O "$fastp_dir/dedup.R2.fq.gz" \
            --dedup \
            -A \
            -G \
            -Q \
            -L \
            -j "$fastp_dir/dedup.json" \
            -h /dev/null \
            -w "$THREADS"
    done
    cp "$fastp_dir/timing_run2.txt" "$fastp_dir/timing.txt"

    local fastp_reads_out
    fastp_reads_out=$(count_reads_paired "$fastp_dir/dedup.R1.fq.gz" "$fastp_dir/dedup.R2.fq.gz")
    log_done "fastp: $fastp_reads_out reads out"

    # ── Results ──────────────────────────────────────────────────────
    local results="$workdir/results.tsv"
    write_result_header "$results"

    local clump_timing fastp_timing
    read -r clump_wall clump_rss clump_cpu <<< "$(parse_timing "$clump_dir/timing.txt")"
    read -r fastp_wall fastp_rss fastp_cpu <<< "$(parse_timing "$fastp_dir/timing.txt")"

    write_result_row "$results" "clumpify" "$clump_wall" "$clump_rss" "$clump_cpu" "$reads_in" "$clump_reads_out"
    write_result_row "$results" "fastp" "$fastp_wall" "$fastp_rss" "$fastp_cpu" "$reads_in" "$fastp_reads_out"

    log_info ""
    log_info "=== B1 Results ==="
    column -t -s$'\t' "$results"
    log_done "Results written to $results"
}
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/benchmark-vsp2.sh
```

Expected: Still fails because `cmd_scrub`, `cmd_merge`, etc. are undefined. Add stubs for the remaining commands right before the `case` dispatch block:

```bash
# ── Stubs for not-yet-implemented subcommands ────────────────────────
cmd_scrub() { echo "Not yet implemented"; exit 1; }
cmd_merge() { echo "Not yet implemented"; exit 1; }
cmd_e2e()   { echo "Not yet implemented"; exit 1; }
cmd_report(){ echo "Not yet implemented"; exit 1; }
```

Then re-check:
```bash
bash -n scripts/benchmark-vsp2.sh
echo $?
```

Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2.sh
git commit -m "feat: add B1 dedup benchmark (clumpify vs fastp --dedup)"
```

---

### Task 4: Implement the scrub benchmark (B2: STAT vs deacon)

**Files:**
- Modify: `scripts/benchmark-vsp2.sh`

- [ ] **Step 1: Replace the `cmd_scrub` stub with the full implementation**

```bash
# ── B2: scrub ────────────────────────────────────────────────────────
cmd_scrub() {
    log_info "=== B2: Human Read Removal — sra-human-scrubber vs deacon ==="
    local workdir
    workdir=$(ensure_workdir "B2-scrub")

    # Use raw input (not deduped) so this benchmark is independent of B1
    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads: $reads_in"

    # ── sra-human-scrubber (STAT) ────────────────────────────────────
    local stat_dir="$workdir/stat"
    mkdir -p "$stat_dir"

    log_info "Running sra-human-scrubber..."

    # STAT requires plain-text interleaved input
    log_info "  Decompressing and interleaving input..."
    bbtools_env
    "$REFORMAT" "in=$R1" "in2=$R2" \
        "out=$stat_dir/interleaved.fq" \
        "threads=$THREADS" "ow=t"

    for run in 1 2; do
        log_info "  scrub.sh run $run/2..."
        run_timed "$stat_dir/timing_run${run}.txt" \
            /bin/bash "$SCRUB_SH" \
            -i "$stat_dir/interleaved.fq" \
            -o "$stat_dir/scrubbed.fq" \
            -d "$SCRUBBER_DB" \
            -p "$THREADS" \
            -s \
            -x
    done
    cp "$stat_dir/timing_run2.txt" "$stat_dir/timing.txt"

    # Compress output for consistent read counting
    "$PIGZ" -p "$THREADS" -c "$stat_dir/scrubbed.fq" > "$stat_dir/scrubbed.fq.gz"

    local stat_reads_out
    stat_reads_out=$(count_reads_paired "$stat_dir/scrubbed.fq.gz")
    log_done "STAT: $stat_reads_out reads out"

    # Clean up large intermediate
    rm -f "$stat_dir/interleaved.fq" "$stat_dir/scrubbed.fq"

    # ── Deacon ───────────────────────────────────────────────────────
    local deacon_dir="$workdir/deacon"
    mkdir -p "$deacon_dir"

    log_info "Running deacon filter..."

    if [[ ! -f "$DEACON_DB" ]]; then
        echo "ERROR: Deacon index not found at: $DEACON_DB" >&2
        echo "Run './scripts/benchmark-vsp2.sh setup' first." >&2
        exit 1
    fi

    for run in 1 2; do
        log_info "  deacon run $run/2..."
        run_timed "$deacon_dir/timing_run${run}.txt" \
            run_deacon filter -d \
            "$DEACON_DB" \
            "$R1" "$R2" \
            -o "$deacon_dir/scrubbed.R1.fq.gz" \
            -O "$deacon_dir/scrubbed.R2.fq.gz" \
            -t "$THREADS"
    done
    cp "$deacon_dir/timing_run2.txt" "$deacon_dir/timing.txt"

    local deacon_reads_out
    deacon_reads_out=$(count_reads_paired "$deacon_dir/scrubbed.R1.fq.gz" "$deacon_dir/scrubbed.R2.fq.gz")
    log_done "Deacon: $deacon_reads_out reads out"

    # ── Results ──────────────────────────────────────────────────────
    local results="$workdir/results.tsv"
    write_result_header "$results"

    local stat_wall stat_rss stat_cpu deacon_wall deacon_rss deacon_cpu
    read -r stat_wall stat_rss stat_cpu <<< "$(parse_timing "$stat_dir/timing.txt")"
    read -r deacon_wall deacon_rss deacon_cpu <<< "$(parse_timing "$deacon_dir/timing.txt")"

    write_result_row "$results" "stat" "$stat_wall" "$stat_rss" "$stat_cpu" "$reads_in" "$stat_reads_out"
    write_result_row "$results" "deacon" "$deacon_wall" "$deacon_rss" "$deacon_cpu" "$reads_in" "$deacon_reads_out"

    log_info ""
    log_info "=== B2 Results ==="
    column -t -s$'\t' "$results"
    log_done "Results written to $results"
}
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/benchmark-vsp2.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2.sh
git commit -m "feat: add B2 scrub benchmark (sra-human-scrubber vs deacon)"
```

---

### Task 5: Implement the merge benchmark (B3: bbmerge vs fastp --merge)

**Files:**
- Modify: `scripts/benchmark-vsp2.sh`

- [ ] **Step 1: Replace the `cmd_merge` stub with the full implementation**

```bash
# ── B3: merge ────────────────────────────────────────────────────────
cmd_merge() {
    log_info "=== B3: Paired-End Merge — bbmerge.sh vs fastp --merge ==="
    local workdir
    workdir=$(ensure_workdir "B3-merge")

    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads (pairs): $reads_in"

    # ── bbmerge ──────────────────────────────────────────────────────
    local bbm_dir="$workdir/bbmerge"
    mkdir -p "$bbm_dir"

    log_info "Running bbmerge.sh..."
    bbtools_env

    # bbmerge expects interleaved input
    log_info "  Interleaving input..."
    "$REFORMAT" "in=$R1" "in2=$R2" \
        "out=$bbm_dir/interleaved.fq.gz" \
        "threads=$THREADS" "ow=t"

    for run in 1 2; do
        log_info "  bbmerge run $run/2..."
        run_timed "$bbm_dir/timing_run${run}.txt" \
            "$BBMERGE" \
            "in=$bbm_dir/interleaved.fq.gz" \
            "out=$bbm_dir/merged.fq.gz" \
            "outu=$bbm_dir/unmerged.fq.gz" \
            "minoverlap=15" \
            "-Xmx${HEAP_GB}g" \
            "threads=$THREADS" \
            "ow=t"
    done
    cp "$bbm_dir/timing_run2.txt" "$bbm_dir/timing.txt"

    local bbm_merged bbm_unmerged
    bbm_merged=$(count_reads_paired "$bbm_dir/merged.fq.gz")
    bbm_unmerged=$(count_reads_paired "$bbm_dir/unmerged.fq.gz")
    log_done "bbmerge: $bbm_merged merged, $bbm_unmerged unmerged"

    # Clean up large intermediate
    rm -f "$bbm_dir/interleaved.fq.gz"

    # ── fastp --merge ────────────────────────────────────────────────
    local fp_dir="$workdir/fastp"
    mkdir -p "$fp_dir"

    log_info "Running fastp --merge..."
    for run in 1 2; do
        log_info "  fastp run $run/2..."
        run_timed "$fp_dir/timing_run${run}.txt" \
            "$FASTP" \
            -i "$R1" -I "$R2" \
            --merge \
            --merged_out "$fp_dir/merged.fq.gz" \
            --out1 "$fp_dir/unmerged.R1.fq.gz" \
            --out2 "$fp_dir/unmerged.R2.fq.gz" \
            --overlap_len_require 15 \
            -A -G -Q -L \
            -j "$fp_dir/merge.json" \
            -h /dev/null \
            -w "$THREADS"
    done
    cp "$fp_dir/timing_run2.txt" "$fp_dir/timing.txt"

    local fp_merged fp_unmerged
    fp_merged=$(count_reads_paired "$fp_dir/merged.fq.gz")
    fp_unmerged=$(count_reads_paired "$fp_dir/unmerged.R1.fq.gz" "$fp_dir/unmerged.R2.fq.gz")
    log_done "fastp: $fp_merged merged, $fp_unmerged unmerged"

    # ── Results ──────────────────────────────────────────────────────
    local results="$workdir/results.tsv"
    echo -e "tool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\tmerged\tunmerged\tpct_merged" > "$results"

    local bbm_wall bbm_rss bbm_cpu fp_wall fp_rss fp_cpu
    read -r bbm_wall bbm_rss bbm_cpu <<< "$(parse_timing "$bbm_dir/timing.txt")"
    read -r fp_wall fp_rss fp_cpu <<< "$(parse_timing "$fp_dir/timing.txt")"

    local bbm_pct fp_pct
    bbm_pct=$(awk "BEGIN {printf \"%.2f\", $bbm_merged / ($bbm_merged + $bbm_unmerged) * 100}")
    fp_pct=$(awk "BEGIN {printf \"%.2f\", $fp_merged / ($fp_merged + $fp_unmerged) * 100}")

    echo -e "bbmerge\t${bbm_wall}\t${bbm_rss}\t${bbm_cpu}\t${reads_in}\t${bbm_merged}\t${bbm_unmerged}\t${bbm_pct}" >> "$results"
    echo -e "fastp\t${fp_wall}\t${fp_rss}\t${fp_cpu}\t${reads_in}\t${fp_merged}\t${fp_unmerged}\t${fp_pct}" >> "$results"

    log_info ""
    log_info "=== B3 Results ==="
    column -t -s$'\t' "$results"
    log_done "Results written to $results"
}
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/benchmark-vsp2.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2.sh
git commit -m "feat: add B3 merge benchmark (bbmerge vs fastp --merge)"
```

---

### Task 6: Implement the end-to-end pipeline comparison

**Files:**
- Modify: `scripts/benchmark-vsp2.sh`

- [ ] **Step 1: Replace the `cmd_e2e` stub with the full implementation**

This runs the complete 6-step VSP2 recipe twice — once with current tools, once with candidates. The adapter trim, quality trim, and length filter steps are identical in both pipelines (they use fastp and seqkit, which aren't under evaluation).

```bash
# ── E2E: full pipeline comparison ────────────────────────────────────
cmd_e2e() {
    log_info "=== E2E: Full VSP2 Pipeline — current vs optimized ==="
    local workdir
    workdir=$(ensure_workdir "E2E")

    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads: $reads_in"

    # ── Pipeline A: current tools ────────────────────────────────────
    local a_dir="$workdir/current"
    mkdir -p "$a_dir"
    log_info "--- Pipeline A: current tools ---"

    local a_start a_end
    a_start=$(date +%s)
    bbtools_env

    # Step 1: Deduplicate with clumpify
    log_info "  [A1] clumpify dedup..."
    run_timed "$a_dir/timing_dedup.txt" \
        "$CLUMPIFY" \
        "in=$R1" "in2=$R2" \
        "out=$a_dir/dedup.R1.fq.gz" "out2=$a_dir/dedup.R2.fq.gz" \
        "dedupe=t" "subs=0" "reorder" "groups=auto" \
        "pigz=t" "zl=4" "-Xmx${HEAP_GB}g" "threads=$THREADS" "ow=t"

    # Step 2+3: Adapter trim + quality trim with fastp
    log_info "  [A2-3] fastp adapter+quality trim..."
    run_timed "$a_dir/timing_trim.txt" \
        "$FASTP" \
        -i "$a_dir/dedup.R1.fq.gz" -I "$a_dir/dedup.R2.fq.gz" \
        -o "$a_dir/trimmed.R1.fq.gz" -O "$a_dir/trimmed.R2.fq.gz" \
        --detect_adapter_for_pe \
        -q 15 -W 5 --cut_right \
        -j "$a_dir/trim.json" -h /dev/null \
        -w "$THREADS"

    # Step 4: Human scrub with STAT (needs interleaved plain text)
    log_info "  [A4] Interleaving for STAT..."
    "$REFORMAT" "in=$a_dir/trimmed.R1.fq.gz" "in2=$a_dir/trimmed.R2.fq.gz" \
        "out=$a_dir/interleaved.fq" "threads=$THREADS" "ow=t"

    log_info "  [A4] sra-human-scrubber..."
    run_timed "$a_dir/timing_scrub.txt" \
        /bin/bash "$SCRUB_SH" \
        -i "$a_dir/interleaved.fq" \
        -o "$a_dir/scrubbed.fq" \
        -d "$SCRUBBER_DB" \
        -p "$THREADS" -s -x

    # Compress scrubbed output
    "$PIGZ" -p "$THREADS" -c "$a_dir/scrubbed.fq" > "$a_dir/scrubbed.fq.gz"
    rm -f "$a_dir/interleaved.fq" "$a_dir/scrubbed.fq"

    # Step 5: Merge with bbmerge (interleaved input)
    log_info "  [A5] bbmerge..."
    # De-interleave scrubbed into R1/R2 for consistency, then re-interleave
    # Actually, the scrubbed output is already interleaved from STAT
    # bbmerge can take interleaved input directly
    run_timed "$a_dir/timing_merge.txt" \
        "$BBMERGE" \
        "in=$a_dir/scrubbed.fq.gz" \
        "out=$a_dir/merged.fq.gz" \
        "outu=$a_dir/unmerged.fq.gz" \
        "minoverlap=15" "-Xmx${HEAP_GB}g" "threads=$THREADS" "ow=t"

    # Step 6: Length filter
    log_info "  [A6] seqkit length filter..."
    # Concatenate merged + unmerged, then filter
    cat "$a_dir/merged.fq.gz" "$a_dir/unmerged.fq.gz" > "$a_dir/combined.fq.gz"
    run_timed "$a_dir/timing_filter.txt" \
        "$SEQKIT" seq -m 50 "$a_dir/combined.fq.gz" -o "$a_dir/final.fq.gz"

    a_end=$(date +%s)
    local a_total=$(( a_end - a_start ))
    local a_reads_out
    a_reads_out=$(count_reads_paired "$a_dir/final.fq.gz")
    log_done "Pipeline A: $a_reads_out reads in ${a_total}s"

    # Clean intermediates
    rm -f "$a_dir/dedup.R1.fq.gz" "$a_dir/dedup.R2.fq.gz" \
          "$a_dir/trimmed.R1.fq.gz" "$a_dir/trimmed.R2.fq.gz" \
          "$a_dir/scrubbed.fq.gz" "$a_dir/merged.fq.gz" \
          "$a_dir/unmerged.fq.gz" "$a_dir/combined.fq.gz"

    # ── Pipeline B: optimized tools ──────────────────────────────────
    local b_dir="$workdir/optimized"
    mkdir -p "$b_dir"
    log_info "--- Pipeline B: optimized tools ---"

    local b_start b_end
    b_start=$(date +%s)

    # Step 1: Deduplicate with fastp (also do adapter + quality trim in one pass)
    log_info "  [B1-3] fastp dedup+adapter+quality trim..."
    run_timed "$b_dir/timing_dedup_trim.txt" \
        "$FASTP" \
        -i "$R1" -I "$R2" \
        -o "$b_dir/processed.R1.fq.gz" -O "$b_dir/processed.R2.fq.gz" \
        --dedup \
        --detect_adapter_for_pe \
        -q 15 -W 5 --cut_right \
        -j "$b_dir/dedup_trim.json" -h /dev/null \
        -w "$THREADS"

    # Step 4: Human scrub with deacon
    log_info "  [B4] deacon filter..."
    if [[ ! -f "$DEACON_DB" ]]; then
        echo "ERROR: Deacon index not found. Run setup first." >&2; exit 1
    fi
    run_timed "$b_dir/timing_scrub.txt" \
        run_deacon filter -d \
        "$DEACON_DB" \
        "$b_dir/processed.R1.fq.gz" "$b_dir/processed.R2.fq.gz" \
        -o "$b_dir/scrubbed.R1.fq.gz" \
        -O "$b_dir/scrubbed.R2.fq.gz" \
        -t "$THREADS"

    # Step 5: Merge with fastp
    log_info "  [B5] fastp merge..."
    run_timed "$b_dir/timing_merge.txt" \
        "$FASTP" \
        -i "$b_dir/scrubbed.R1.fq.gz" -I "$b_dir/scrubbed.R2.fq.gz" \
        --merge \
        --merged_out "$b_dir/merged.fq.gz" \
        --out1 "$b_dir/unmerged.R1.fq.gz" \
        --out2 "$b_dir/unmerged.R2.fq.gz" \
        --overlap_len_require 15 \
        -A -G -Q -L \
        -j "$b_dir/merge.json" -h /dev/null \
        -w "$THREADS"

    # Step 6: Length filter
    log_info "  [B6] seqkit length filter..."
    cat "$b_dir/merged.fq.gz" "$b_dir/unmerged.R1.fq.gz" "$b_dir/unmerged.R2.fq.gz" > "$b_dir/combined.fq.gz"
    run_timed "$b_dir/timing_filter.txt" \
        "$SEQKIT" seq -m 50 "$b_dir/combined.fq.gz" -o "$b_dir/final.fq.gz"

    b_end=$(date +%s)
    local b_total=$(( b_end - b_start ))
    local b_reads_out
    b_reads_out=$(count_reads_paired "$b_dir/final.fq.gz")
    log_done "Pipeline B: $b_reads_out reads in ${b_total}s"

    # Clean intermediates
    rm -f "$b_dir/processed.R1.fq.gz" "$b_dir/processed.R2.fq.gz" \
          "$b_dir/scrubbed.R1.fq.gz" "$b_dir/scrubbed.R2.fq.gz" \
          "$b_dir/merged.fq.gz" "$b_dir/unmerged.R1.fq.gz" \
          "$b_dir/unmerged.R2.fq.gz" "$b_dir/combined.fq.gz"

    # ── Results ──────────────────────────────────────────────────────
    local results="$workdir/results.tsv"
    echo -e "pipeline\ttotal_sec\treads_in\treads_out\tpct_retained" > "$results"

    local a_pct b_pct
    a_pct=$(awk "BEGIN {printf \"%.2f\", $a_reads_out / $reads_in * 100}")
    b_pct=$(awk "BEGIN {printf \"%.2f\", $b_reads_out / $reads_in * 100}")

    echo -e "current\t${a_total}\t${reads_in}\t${a_reads_out}\t${a_pct}" >> "$results"
    echo -e "optimized\t${b_total}\t${reads_in}\t${b_reads_out}\t${b_pct}" >> "$results"

    log_info ""
    log_info "=== E2E Results ==="
    column -t -s$'\t' "$results"

    local speedup
    speedup=$(awk "BEGIN {printf \"%.1f\", $a_total / $b_total}")
    log_info "Speedup: ${speedup}x"
    log_done "Results written to $results"
}
```

**Key design note**: Pipeline B combines dedup + adapter trim + quality trim into a single fastp invocation (steps 1–3 in one pass). This tests whether fastp can consolidate three separate operations, which is the main throughput win if fastp's dedup is comparable to clumpify.

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/benchmark-vsp2.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2.sh
git commit -m "feat: add E2E pipeline comparison (current vs optimized)"
```

---

### Task 7: Implement the report subcommand

**Files:**
- Modify: `scripts/benchmark-vsp2.sh`

- [ ] **Step 1: Replace the `cmd_report` stub with the full implementation**

```bash
# ── report ───────────────────────────────────────────────────────────
cmd_report() {
    log_info "=== VSP2 Benchmark Summary ==="

    # Find the most recent benchmark directory
    local latest
    latest=$(ls -d "$PROJECT_ROOT"/benchmarks/vsp2-* 2>/dev/null | sort | tail -1)
    if [[ -z "$latest" ]]; then
        echo "No benchmark results found. Run benchmarks first." >&2
        exit 1
    fi
    log_info "Results from: $latest"
    echo ""

    for bench in B1-dedup B2-scrub B3-merge E2E; do
        local results="$latest/$bench/results.tsv"
        if [[ -f "$results" ]]; then
            echo "── $bench ──────────────────────────────────────────"
            column -t -s$'\t' "$results"
            echo ""
        fi
    done

    # Write combined summary.tsv
    local summary="$latest/summary.tsv"
    echo -e "benchmark\ttool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\treads_out\tpct_change" > "$summary"
    for bench in B1-dedup B2-scrub B3-merge; do
        local results="$latest/$bench/results.tsv"
        if [[ -f "$results" ]]; then
            tail -n +2 "$results" | while IFS=$'\t' read -r line; do
                echo -e "${bench}\t${line}" >> "$summary"
            done
        fi
    done

    log_done "Summary written to $summary"
}
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/benchmark-vsp2.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark-vsp2.sh
git commit -m "feat: add report subcommand to summarize benchmark results"
```

---

### Task 8: Run setup and verify tool installation

- [ ] **Step 1: Run the setup subcommand**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
./scripts/benchmark-vsp2.sh setup
```

Expected output (approximate):
```
[HH:MM:SS] Setting up benchmarking environment...
[HH:MM:SS] Creating conda environment 'deacon-bench' with deacon...
...
[HH:MM:SS] Deacon binary: /Users/dho/miniforge3/envs/deacon-bench/bin/deacon
deacon 0.15.0
[HH:MM:SS] Downloading panhuman-1 index (3.3 GB)...
...
[HH:MM:SS] Test data R1: ... (1.8G)
[HH:MM:SS] Test data R2: ... (2.2G)
[HH:MM:SS] Threads: N
[HH:MM:SS] Java heap: 9g
[HH:MM:SS] ✓ Setup complete
```

If `deacon index fetch` stores the file in an unexpected location, check the deacon output for the download path and adjust the setup function accordingly.

- [ ] **Step 2: Verify deacon works on a small test**

```bash
# Quick sanity check — run deacon on a tiny subset
cd /Users/dho/Documents/lungfish-genome-explorer
zcat "$R1_PATH" | head -4000 | gzip > /tmp/test_r1.fq.gz
zcat "$R2_PATH" | head -4000 | gzip > /tmp/test_r2.fq.gz
$HOME/miniforge3/bin/conda run -n deacon-bench \
    deacon filter -d \
    "$HOME/Library/Application Support/Lungfish/databases/deacon/panhuman-1.k31w15.idx" \
    /tmp/test_r1.fq.gz /tmp/test_r2.fq.gz \
    -o /tmp/test_filt_r1.fq.gz -O /tmp/test_filt_r2.fq.gz -t 4
echo "Exit code: $?"
rm /tmp/test_r1.fq.gz /tmp/test_r2.fq.gz /tmp/test_filt_r1.fq.gz /tmp/test_filt_r2.fq.gz
```

Expected: Exit code 0, no errors.

- [ ] **Step 3: No commit needed (runtime verification only)**

---

### Task 9: Run individual benchmarks (B1, B2, B3)

These are long-running operations. Each benchmark processes ~4GB of compressed FASTQ data twice (two runs per tool).

- [ ] **Step 1: Run B1 (dedup benchmark)**

```bash
./scripts/benchmark-vsp2.sh dedup
```

Expected: Completes after ~10–30 minutes (depending on I/O). Prints a comparison table. Review the results.tsv for:
- Both tools produce similar read counts (within 5%)
- Peak RSS for both tools < 12 GB
- Any errors in timing.txt files

- [ ] **Step 2: Run B2 (scrub benchmark)**

```bash
./scripts/benchmark-vsp2.sh scrub
```

Expected: Completes after ~10–40 minutes. Review that:
- Human read removal percentages are in the same ballpark (within 5%)
- Deacon peak RSS < 12 GB
- Output files are valid FASTQ

- [ ] **Step 3: Run B3 (merge benchmark)**

```bash
./scripts/benchmark-vsp2.sh merge
```

Expected: Completes after ~10–20 minutes. Review that:
- Merge percentages are similar (within 5%)
- Both tools produce valid paired output

- [ ] **Step 4: Fix any issues discovered during benchmarks**

If timing parsing, read counting, or tool invocations have issues, fix the scripts and re-run the failing benchmark. Common issues:
- macOS `/usr/bin/time -l` output format may differ from expected parsing
- seqkit stats format for gzipped vs plain files
- Deacon paired-end output naming

- [ ] **Step 5: Commit any script fixes**

```bash
git add scripts/benchmark-vsp2.sh scripts/benchmark-vsp2-lib.sh
git commit -m "fix: adjust benchmark scripts based on initial run results"
```

---

### Task 10: Run E2E comparison and generate report

- [ ] **Step 1: Run the end-to-end comparison**

```bash
./scripts/benchmark-vsp2.sh e2e
```

Expected: Completes after ~30–90 minutes (runs full pipeline twice). Prints total time and read counts for both pipelines.

- [ ] **Step 2: Generate the report**

```bash
./scripts/benchmark-vsp2.sh report
```

Expected: Prints all benchmark results in a formatted table and writes `summary.tsv`.

- [ ] **Step 3: Review results against success criteria**

Check each benchmark against the spec's success criteria:
1. Speed: Is the candidate >10% faster?
2. Reads: Is retention within 5% of current?
3. Memory: Is peak RSS < 12 GB?
4. Correctness: Are output files valid?

- [ ] **Step 4: Commit final results notes**

If any script adjustments were needed during E2E, commit them:
```bash
git add scripts/
git commit -m "fix: finalize benchmark scripts after E2E validation"
```
