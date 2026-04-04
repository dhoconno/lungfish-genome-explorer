#!/usr/bin/env bash
# benchmark-vsp2.sh — VSP2 pipeline optimization benchmark suite
#
# Subcommands:
#   setup   — create conda env, download deacon index, verify tools & data
#   dedup   — B1: clumpify vs fastp --dedup
#   scrub   — B2: sra-human-scrubber (STAT) vs deacon
#   merge   — B3: bbmerge vs fastp --merge
#   e2e     — full pipeline A (current) vs pipeline B (optimized)
#   report  — summarise most recent benchmark run
#   help    — show usage
#
# Usage:
#   ./scripts/benchmark-vsp2.sh <subcommand>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/benchmark-vsp2-lib.sh"

# ---------------------------------------------------------------------------
# Conda / deacon
# ---------------------------------------------------------------------------
CONDA="${HOME}/miniforge3/bin/conda"
DEACON_ENV="deacon-bench"

run_deacon() {
    "$CONDA" run --no-banner -n "$DEACON_ENV" deacon "$@"
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
cmd_help() {
    cat <<'EOF'
benchmark-vsp2.sh — VSP2 pipeline optimization benchmark suite

Subcommands:
  setup    Create conda env + download deacon index; verify tools and data
  dedup    B1: clumpify vs fastp --dedup
  scrub    B2: sra-human-scrubber (STAT) vs deacon
  merge    B3: bbmerge vs fastp --merge
  e2e      Full pipeline A (current) vs pipeline B (optimised)
  report   Summarise the most recent benchmark run directory
  help     Show this message

Environment overrides:
  BENCH_R1   Path to R1 FASTQ.gz (default: NVMe test dataset)
  BENCH_R2   Path to R2 FASTQ.gz
  THREADS    Number of threads (default: performance core count / ncpu/2)
EOF
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
cmd_setup() {
    log_info "=== setup: verifying environment ==="

    # 1. Conda env for deacon
    if "$CONDA" env list 2>/dev/null | grep -q "^${DEACON_ENV}[[:space:]]"; then
        log_info "Conda env '${DEACON_ENV}' already exists — skipping creation"
    else
        log_info "Creating conda env '${DEACON_ENV}' with deacon from bioconda..."
        "$CONDA" create -y -n "$DEACON_ENV" \
            -c bioconda -c conda-forge \
            deacon
        log_done "Conda env created"
    fi

    # 2. Deacon panhuman-1 index
    local deacon_db_dir
    deacon_db_dir="$(dirname "$DEACON_DB")"
    if [[ -f "$DEACON_DB" ]]; then
        log_info "Deacon index already present: ${DEACON_DB}"
    else
        log_info "Fetching panhuman-1 index via deacon index fetch..."
        mkdir -p "$deacon_db_dir"
        if run_deacon index fetch panhuman-1 2>&1; then
            # deacon may place the file in the current working dir or a default cache;
            # find it and move to the expected location if necessary.
            local idx
            idx=$(find "${HOME}/Library/Application Support/Lungfish/databases" \
                       "${HOME}/.deacon" "${HOME}/.local/share/deacon" \
                       "$(pwd)" \
                  -name "panhuman-1.k31w15.idx" 2>/dev/null | head -n1 || true)
            if [[ -n "$idx" && "$idx" != "$DEACON_DB" ]]; then
                log_info "Moving index from ${idx} to ${DEACON_DB}"
                mv "$idx" "$DEACON_DB"
            elif [[ -z "$idx" ]]; then
                log_info "deacon fetch did not place index in expected location; trying direct download..."
                curl -L --progress-bar \
                    "https://objectstorage.uk-london-1.oraclecloud.com/n/lrbvkel2wjot/b/human-genome-bucket/o/deacon/3/panhuman-1.k31w15.idx" \
                    -o "$DEACON_DB"
            fi
        else
            log_info "deacon index fetch failed; falling back to direct curl..."
            curl -L --progress-bar \
                "https://objectstorage.uk-london-1.oraclecloud.com/n/lrbvkel2wjot/b/human-genome-bucket/o/deacon/3/panhuman-1.k31w15.idx" \
                -o "$DEACON_DB"
        fi
        log_done "Deacon index downloaded"
    fi

    # 3. Write manifest.json for DatabaseRegistry compatibility
    local manifest_path="${deacon_db_dir}/manifest.json"
    if [[ ! -f "$manifest_path" ]]; then
        log_info "Writing manifest.json for DatabaseRegistry..."
        cat > "$manifest_path" <<EOF
{
  "name": "Deacon panhuman-1",
  "version": "1",
  "kmer_size": 31,
  "window_size": 15,
  "source_url": "https://objectstorage.uk-london-1.oraclecloud.com/n/lrbvkel2wjot/b/human-genome-bucket/o/deacon/3/panhuman-1.k31w15.idx",
  "database_file": "panhuman-1.k31w15.idx"
}
EOF
        log_done "manifest.json written"
    fi

    # 4. Verify test data
    log_info "Verifying test data..."
    local missing=0
    for f in "$R1" "$R2"; do
        if [[ ! -f "$f" ]]; then
            log_info "WARNING: test data file not found: ${f}"
            missing=$(( missing + 1 ))
        else
            log_info "  OK: ${f}"
        fi
    done
    [[ "$missing" -gt 0 ]] && log_info "WARNING: ${missing} test data file(s) missing — benchmarks will fail"

    # 5. Verify bundled tools
    log_info "Verifying bundled tools..."
    local tools_ok=1
    for bin in "$FASTP" "$PIGZ" "$SEQKIT" "$CLUMPIFY" "$BBMERGE" "$REFORMAT"; do
        if [[ ! -x "$bin" ]]; then
            log_info "  MISSING: ${bin}"
            tools_ok=0
        else
            log_info "  OK: ${bin}"
        fi
    done
    if [[ ! -f "$SCRUB_SH" ]]; then
        log_info "  MISSING scrub.sh: ${SCRUB_SH}"
        tools_ok=0
    else
        log_info "  OK: ${SCRUB_SH}"
    fi
    if [[ "$tools_ok" -eq 0 ]]; then
        log_info "WARNING: one or more bundled tools are missing"
    fi

    log_done "setup complete"
}

# ---------------------------------------------------------------------------
# dedup  (B1: clumpify vs fastp --dedup)
# ---------------------------------------------------------------------------
cmd_dedup() {
    log_info "=== B1: dedup benchmark ==="
    bbtools_env

    local workdir
    workdir=$(ensure_workdir "b1-dedup")
    log_info "Working directory: ${workdir}"

    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads (R1+R2): ${reads_in}"

    local results_tsv="${workdir}/results.tsv"
    write_result_header "$results_tsv"

    # --- clumpify warm-up ---
    log_info "clumpify: warm-up run..."
    "$CLUMPIFY" \
        in="$R1" in2="$R2" \
        out="${workdir}/warmup.R1.fq.gz" out2="${workdir}/warmup.R2.fq.gz" \
        dedupe=t subs=0 reorder groups=auto pigz=t zl=4 \
        "-Xmx${HEAP_GB}g" threads="$THREADS" ow=t \
        2>/dev/null || true
    rm -f "${workdir}/warmup.R1.fq.gz" "${workdir}/warmup.R2.fq.gz"

    # --- clumpify timed run ---
    log_info "clumpify: timed run..."
    run_timed "${workdir}/clumpify.time" \
        "$CLUMPIFY" \
            in="$R1" in2="$R2" \
            out="${workdir}/clumpify.R1.fq.gz" out2="${workdir}/clumpify.R2.fq.gz" \
            dedupe=t subs=0 reorder groups=auto pigz=t zl=4 \
            "-Xmx${HEAP_GB}g" threads="$THREADS" ow=t

    local clumpify_timing
    read -r clumpify_wall clumpify_rss clumpify_cpu < <(parse_timing "${workdir}/clumpify.time")
    local clumpify_reads_out
    clumpify_reads_out=$(count_reads_paired \
        "${workdir}/clumpify.R1.fq.gz" "${workdir}/clumpify.R2.fq.gz")
    write_result_row "$results_tsv" "clumpify" \
        "$clumpify_wall" "$clumpify_rss" "$clumpify_cpu" \
        "$reads_in" "$clumpify_reads_out"
    log_done "clumpify: wall=${clumpify_wall}s  rss=${clumpify_rss}MB  reads_out=${clumpify_reads_out}"

    # --- fastp warm-up ---
    log_info "fastp: warm-up run..."
    "$FASTP" \
        -i "$R1" -I "$R2" \
        -o "${workdir}/warmup.R1.fq.gz" -O "${workdir}/warmup.R2.fq.gz" \
        --dedup -A -G -Q -L \
        -j "${workdir}/warmup_dedup.json" -h /dev/null \
        -w "$THREADS" 2>/dev/null || true
    rm -f "${workdir}/warmup.R1.fq.gz" "${workdir}/warmup.R2.fq.gz" \
          "${workdir}/warmup_dedup.json"

    # --- fastp timed run ---
    log_info "fastp: timed run..."
    run_timed "${workdir}/fastp.time" \
        "$FASTP" \
            -i "$R1" -I "$R2" \
            -o "${workdir}/fastp.R1.fq.gz" -O "${workdir}/fastp.R2.fq.gz" \
            --dedup -A -G -Q -L \
            -j "${workdir}/fastp_dedup.json" -h /dev/null \
            -w "$THREADS"

    local fastp_wall fastp_rss fastp_cpu
    read -r fastp_wall fastp_rss fastp_cpu < <(parse_timing "${workdir}/fastp.time")
    local fastp_reads_out
    fastp_reads_out=$(count_reads_paired \
        "${workdir}/fastp.R1.fq.gz" "${workdir}/fastp.R2.fq.gz")
    write_result_row "$results_tsv" "fastp_dedup" \
        "$fastp_wall" "$fastp_rss" "$fastp_cpu" \
        "$reads_in" "$fastp_reads_out"
    log_done "fastp: wall=${fastp_wall}s  rss=${fastp_rss}MB  reads_out=${fastp_reads_out}"

    echo ""
    echo "=== B1 Dedup Results ==="
    column -t "$results_tsv"

    local speedup
    speedup=$(awk "BEGIN { if (${clumpify_wall}+0 > 0) printf \"%.2fx\", ${clumpify_wall} / ${fastp_wall}; else print \"N/A\" }")
    echo ""
    echo "Speedup (clumpify_wall / fastp_wall): ${speedup}"
    log_done "B1 dedup benchmark complete → ${results_tsv}"
}

# ---------------------------------------------------------------------------
# scrub  (B2: sra-human-scrubber/STAT vs deacon)
# ---------------------------------------------------------------------------
cmd_scrub() {
    log_info "=== B2: scrub benchmark ==="
    bbtools_env

    local workdir
    workdir=$(ensure_workdir "b2-scrub")
    log_info "Working directory: ${workdir}"

    if [[ ! -f "$SCRUB_SH" ]]; then
        log_info "ERROR: scrub.sh not found at ${SCRUB_SH}"
        exit 1
    fi
    if [[ ! -f "$SCRUBBER_DB" ]]; then
        log_info "ERROR: STAT scrubber DB not found at ${SCRUBBER_DB}"
        exit 1
    fi
    if [[ ! -f "$DEACON_DB" ]]; then
        log_info "ERROR: Deacon DB not found at ${DEACON_DB} — run setup first"
        exit 1
    fi

    # Count input reads (independent of B1 outputs — use raw R1/R2)
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads (R1+R2): ${reads_in}"

    local results_tsv="${workdir}/results.tsv"
    write_result_header "$results_tsv"

    # -----------------------------------------------------------------------
    # STAT (sra-human-scrubber)
    # Requires plain-text interleaved input; output is also interleaved.
    # Timing covers the full pipeline cost: interleave + scrub + compress.
    # Deacon operates directly on paired gz, so including these steps
    # in STAT's wall time gives an apples-to-apples comparison.
    # -----------------------------------------------------------------------
    local stat_dir="${workdir}/stat"
    mkdir -p "$stat_dir"

    for run in 1 2; do
        log_info "  STAT run ${run}/2..."
        local t_start t_end
        t_start=$(date +%s)

        log_info "  STAT [${run}/2]: interleaving input..."
        "$REFORMAT" \
            in="$R1" in2="$R2" \
            out="${stat_dir}/interleaved.fq" \
            2>/dev/null

        log_info "  STAT [${run}/2]: scrubbing..."
        bash "$SCRUB_SH" \
            -i "${stat_dir}/interleaved.fq" \
            -o "${stat_dir}/scrubbed.fq" \
            -d "$SCRUBBER_DB" \
            -p "$THREADS" \
            -s -x

        log_info "  STAT [${run}/2]: compressing..."
        "$PIGZ" -p "$THREADS" -4 -f "${stat_dir}/scrubbed.fq"
        # pigz -f allows overwrite on run 2

        rm -f "${stat_dir}/interleaved.fq"

        t_end=$(date +%s)
        local t_wall=$(( t_end - t_start ))
        printf "%s real\n" "$t_wall" > "${stat_dir}/timing_run${run}.txt"
    done
    cp "${stat_dir}/timing_run2.txt" "${stat_dir}/timing.txt"

    # Parse wall time from the synthetic timing file (integer seconds from date +%s)
    local stat_wall stat_rss stat_cpu
    stat_wall=$(awk '/real/{print $1}' "${stat_dir}/timing.txt")
    stat_rss="N/A"
    stat_cpu="N/A"

    # scrubbed output is interleaved; seqkit will count all records
    local stat_reads_out
    stat_reads_out=$("$SEQKIT" stats --tabular "${stat_dir}/scrubbed.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    write_result_row "$results_tsv" "stat_scrubber" \
        "$stat_wall" "$stat_rss" "$stat_cpu" \
        "$reads_in" "$stat_reads_out"
    log_done "STAT: wall=${stat_wall}s  reads_out=${stat_reads_out}"

    # -----------------------------------------------------------------------
    # Deacon
    # -----------------------------------------------------------------------
    local deacon_dir="${workdir}/deacon"
    mkdir -p "$deacon_dir"

    # run_timed uses /usr/bin/time -l which cannot exec shell functions;
    # pass the full conda run command directly as an executable invocation.
    for run in 1 2; do
        log_info "  Deacon run ${run}/2..."
        run_timed "${deacon_dir}/timing_run${run}.txt" \
            "$CONDA" run --no-banner -n "$DEACON_ENV" deacon filter \
                -d "$DEACON_DB" \
                "$R1" "$R2" \
                -o "${deacon_dir}/deacon.R1.fq.gz" \
                -O "${deacon_dir}/deacon.R2.fq.gz" \
                -t "$THREADS"
    done
    cp "${deacon_dir}/timing_run2.txt" "${deacon_dir}/timing.txt"

    local deacon_wall deacon_rss deacon_cpu
    read -r deacon_wall deacon_rss deacon_cpu < <(parse_timing "${deacon_dir}/timing.txt")
    local deacon_reads_out
    deacon_reads_out=$(count_reads_paired \
        "${deacon_dir}/deacon.R1.fq.gz" "${deacon_dir}/deacon.R2.fq.gz")
    write_result_row "$results_tsv" "deacon" \
        "$deacon_wall" "$deacon_rss" "$deacon_cpu" \
        "$reads_in" "$deacon_reads_out"
    log_done "Deacon: wall=${deacon_wall}s  rss=${deacon_rss}MB  reads_out=${deacon_reads_out}"

    echo ""
    echo "=== B2 Scrub Results ==="
    column -t "$results_tsv"

    local speedup
    speedup=$(awk "BEGIN { if (${stat_wall}+0 > 0) printf \"%.2fx\", ${stat_wall} / ${deacon_wall}; else print \"N/A\" }")
    echo ""
    echo "Speedup (stat_wall / deacon_wall): ${speedup}"
    log_done "B2 scrub benchmark complete → ${results_tsv}"
}

# ---------------------------------------------------------------------------
# merge  (B3: bbmerge vs fastp --merge)
# ---------------------------------------------------------------------------
cmd_merge() {
    log_info "=== B3: merge benchmark ==="
    bbtools_env

    local workdir
    workdir=$(ensure_workdir "b3-merge")
    log_info "Working directory: ${workdir}"

    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads (R1+R2): ${reads_in}"

    # Custom TSV with merge-specific columns
    local results_tsv="${workdir}/results.tsv"
    printf "tool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\tmerged\tunmerged\tpct_merged\n" \
        > "$results_tsv"

    # -----------------------------------------------------------------------
    # bbmerge — requires interleaved input
    # -----------------------------------------------------------------------
    local bbmerge_dir="${workdir}/bbmerge"
    mkdir -p "$bbmerge_dir"

    log_info "bbmerge: interleaving input..."
    "$REFORMAT" \
        in="$R1" in2="$R2" \
        out="${bbmerge_dir}/interleaved.fq.gz" \
        2>/dev/null

    for run in 1 2; do
        log_info "  bbmerge run ${run}/2..."
        run_timed "${bbmerge_dir}/timing_run${run}.txt" \
            "$BBMERGE" \
                in="${bbmerge_dir}/interleaved.fq.gz" \
                out="${bbmerge_dir}/merged.fq.gz" \
                outu="${bbmerge_dir}/unmerged.fq.gz" \
                minoverlap=15 \
                "-Xmx${HEAP_GB}g" threads="$THREADS" ow=t
    done
    cp "${bbmerge_dir}/timing_run2.txt" "${bbmerge_dir}/timing.txt"

    # Clean interleaved intermediate
    rm -f "${bbmerge_dir}/interleaved.fq.gz"

    local bbmerge_wall bbmerge_rss bbmerge_cpu
    read -r bbmerge_wall bbmerge_rss bbmerge_cpu < <(parse_timing "${bbmerge_dir}/timing.txt")
    local bbmerge_merged bbmerge_unmerged bbmerge_pct
    bbmerge_merged=$("$SEQKIT" stats --tabular "${bbmerge_dir}/merged.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    bbmerge_unmerged=$("$SEQKIT" stats --tabular "${bbmerge_dir}/unmerged.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    bbmerge_pct=$(awk "BEGIN { total=${reads_in}+0; if (total>0) printf \"%.2f\", ${bbmerge_merged}*100/total; else print \"N/A\" }")
    printf "bbmerge\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$bbmerge_wall" "$bbmerge_rss" "$bbmerge_cpu" \
        "$reads_in" "$bbmerge_merged" "$bbmerge_unmerged" "$bbmerge_pct" \
        >> "$results_tsv"
    log_done "bbmerge: wall=${bbmerge_wall}s  rss=${bbmerge_rss}MB  merged=${bbmerge_merged}"

    # -----------------------------------------------------------------------
    # fastp --merge
    # -----------------------------------------------------------------------
    local fastp_dir="${workdir}/fastp"
    mkdir -p "$fastp_dir"

    for run in 1 2; do
        log_info "  fastp merge run ${run}/2..."
        run_timed "${fastp_dir}/timing_run${run}.txt" \
            "$FASTP" \
                -i "$R1" -I "$R2" \
                --merge \
                --merged_out "${fastp_dir}/merged.fq.gz" \
                --out1 "${fastp_dir}/unmerged.R1.fq.gz" \
                --out2 "${fastp_dir}/unmerged.R2.fq.gz" \
                --overlap_len_require 15 \
                -A -G -Q -L \
                -j "${fastp_dir}/fastp_merge.json" -h /dev/null \
                -w "$THREADS"
    done
    cp "${fastp_dir}/timing_run2.txt" "${fastp_dir}/timing.txt"

    local fastp_wall fastp_rss fastp_cpu
    read -r fastp_wall fastp_rss fastp_cpu < <(parse_timing "${fastp_dir}/timing.txt")
    local fastp_merged fastp_unmerged fastp_pct
    fastp_merged=$("$SEQKIT" stats --tabular "${fastp_dir}/merged.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    local fastp_unmerged_r1 fastp_unmerged_r2
    fastp_unmerged_r1=$("$SEQKIT" stats --tabular "${fastp_dir}/unmerged.R1.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    fastp_unmerged_r2=$("$SEQKIT" stats --tabular "${fastp_dir}/unmerged.R2.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    fastp_unmerged=$(( fastp_unmerged_r1 + fastp_unmerged_r2 ))
    fastp_pct=$(awk "BEGIN { total=${reads_in}+0; if (total>0) printf \"%.2f\", ${fastp_merged}*100/total; else print \"N/A\" }")
    printf "fastp_merge\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$fastp_wall" "$fastp_rss" "$fastp_cpu" \
        "$reads_in" "$fastp_merged" "$fastp_unmerged" "$fastp_pct" \
        >> "$results_tsv"
    log_done "fastp: wall=${fastp_wall}s  rss=${fastp_rss}MB  merged=${fastp_merged}"

    echo ""
    echo "=== B3 Merge Results ==="
    column -t "$results_tsv"

    local speedup
    speedup=$(awk "BEGIN { if (${bbmerge_wall}+0 > 0) printf \"%.2fx\", ${bbmerge_wall} / ${fastp_wall}; else print \"N/A\" }")
    echo ""
    echo "Speedup (bbmerge_wall / fastp_wall): ${speedup}"
    log_done "B3 merge benchmark complete → ${results_tsv}"
}

# ---------------------------------------------------------------------------
# e2e  (full pipeline comparison)
# ---------------------------------------------------------------------------
cmd_e2e() {
    log_info "=== E2E: full pipeline benchmark ==="
    bbtools_env

    local workdir
    workdir=$(ensure_workdir "e2e")
    log_info "Working directory: ${workdir}"

    # Count input reads
    log_info "Counting input reads..."
    local reads_in
    reads_in=$(count_reads_paired "$R1" "$R2")
    log_info "Input reads (R1+R2): ${reads_in}"

    local results_tsv="${workdir}/results.tsv"
    printf "pipeline\ttotal_sec\treads_in\treads_out\tpct_retained\n" > "$results_tsv"

    # -----------------------------------------------------------------------
    # Pipeline A — current stack
    # Steps: clumpify dedup → fastp adapter+quality trim →
    #        reformat interleave → scrub → pigz → bbmerge →
    #        cat merged+unmerged | seqkit -m 50
    # -----------------------------------------------------------------------
    log_info "Pipeline A: starting..."
    local a_start a_end
    a_start=$(date +%s)

    local a="${workdir}/pipeA"
    mkdir -p "$a"

    log_info "Pipeline A [1/5]: clumpify dedup..."
    "$CLUMPIFY" \
        in="$R1" in2="$R2" \
        out="${a}/dedup.R1.fq.gz" out2="${a}/dedup.R2.fq.gz" \
        dedupe=t subs=0 reorder groups=auto pigz=t zl=4 \
        "-Xmx${HEAP_GB}g" threads="$THREADS" ow=t

    log_info "Pipeline A [2/5]: fastp adapter+quality trim..."
    "$FASTP" \
        -i "${a}/dedup.R1.fq.gz" -I "${a}/dedup.R2.fq.gz" \
        -o "${a}/trimmed.R1.fq.gz" -O "${a}/trimmed.R2.fq.gz" \
        --detect_adapter_for_pe -q 15 -W 5 --cut_right \
        -A \
        -j "${a}/fastp_trim.json" -h /dev/null \
        -w "$THREADS"
    rm -f "${a}/dedup.R1.fq.gz" "${a}/dedup.R2.fq.gz"

    log_info "Pipeline A [3/5]: reformat interleave + STAT scrub..."
    "$REFORMAT" \
        in="${a}/trimmed.R1.fq.gz" in2="${a}/trimmed.R2.fq.gz" \
        out="${a}/interleaved.fq" \
        2>/dev/null
    rm -f "${a}/trimmed.R1.fq.gz" "${a}/trimmed.R2.fq.gz"

    bash "$SCRUB_SH" \
        -i "${a}/interleaved.fq" \
        -o "${a}/scrubbed.fq" \
        -d "$SCRUBBER_DB" \
        -p "$THREADS" \
        -s -x
    rm -f "${a}/interleaved.fq"

    "$PIGZ" -p "$THREADS" -4 "${a}/scrubbed.fq"
    # scrubbed.fq → scrubbed.fq.gz

    log_info "Pipeline A [4/5]: bbmerge..."
    # bbmerge can read paired interleaved gz directly
    "$BBMERGE" \
        in="${a}/scrubbed.fq.gz" \
        out="${a}/merged.fq.gz" \
        outu="${a}/unmerged.fq.gz" \
        minoverlap=15 \
        "-Xmx${HEAP_GB}g" threads="$THREADS" ow=t
    rm -f "${a}/scrubbed.fq.gz"

    log_info "Pipeline A [5/5]: length filter (>=50 bp)..."
    cat "${a}/merged.fq.gz" "${a}/unmerged.fq.gz" \
        | "$SEQKIT" seq -m 50 --out-file "${a}/final.fq.gz"
    rm -f "${a}/merged.fq.gz" "${a}/unmerged.fq.gz"

    a_end=$(date +%s)
    local a_total_sec=$(( a_end - a_start ))
    local a_reads_out
    a_reads_out=$("$SEQKIT" stats --tabular "${a}/final.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    local a_pct
    a_pct=$(awk "BEGIN { if (${reads_in}+0 > 0) printf \"%.2f\", ${a_reads_out}*100/${reads_in}; else print \"N/A\" }")
    printf "pipeline_A_current\t%s\t%s\t%s\t%s\n" \
        "$a_total_sec" "$reads_in" "$a_reads_out" "$a_pct" \
        >> "$results_tsv"
    log_done "Pipeline A: ${a_total_sec}s  reads_in=${reads_in}  reads_out=${a_reads_out} (${a_pct}%)"

    # -----------------------------------------------------------------------
    # Pipeline B — optimised stack
    # Steps: fastp dedup+adapter+quality in ONE pass →
    #        deacon filter →
    #        fastp --merge on scrubbed R1/R2 →
    #        cat merged+unmerged.R1+unmerged.R2 | seqkit -m 50
    # -----------------------------------------------------------------------
    if [[ ! -f "$DEACON_DB" ]]; then
        log_info "ERROR: Deacon DB not found at ${DEACON_DB} — run setup first"
        exit 1
    fi

    log_info "Pipeline B: starting..."
    local b_start b_end
    b_start=$(date +%s)

    local b="${workdir}/pipeB"
    mkdir -p "$b"

    log_info "Pipeline B [1/3]: fastp dedup + adapter + quality trim (one pass)..."
    "$FASTP" \
        -i "$R1" -I "$R2" \
        -o "${b}/trimmed.R1.fq.gz" -O "${b}/trimmed.R2.fq.gz" \
        --dedup \
        --detect_adapter_for_pe -q 15 -W 5 --cut_right \
        -j "${b}/fastp.json" -h /dev/null \
        -w "$THREADS"

    log_info "Pipeline B [2/3]: deacon filter..."
    run_deacon filter \
        -d "$DEACON_DB" \
        "${b}/trimmed.R1.fq.gz" "${b}/trimmed.R2.fq.gz" \
        -o "${b}/scrubbed.R1.fq.gz" \
        -O "${b}/scrubbed.R2.fq.gz" \
        -t "$THREADS"
    rm -f "${b}/trimmed.R1.fq.gz" "${b}/trimmed.R2.fq.gz"

    log_info "Pipeline B [3/3]: fastp --merge + length filter..."
    "$FASTP" \
        -i "${b}/scrubbed.R1.fq.gz" -I "${b}/scrubbed.R2.fq.gz" \
        --merge \
        --merged_out "${b}/merged.fq.gz" \
        --out1 "${b}/unmerged.R1.fq.gz" \
        --out2 "${b}/unmerged.R2.fq.gz" \
        --overlap_len_require 15 \
        -A -G -Q -L \
        -j "${b}/fastp_merge.json" -h /dev/null \
        -w "$THREADS"
    rm -f "${b}/scrubbed.R1.fq.gz" "${b}/scrubbed.R2.fq.gz"

    cat "${b}/merged.fq.gz" "${b}/unmerged.R1.fq.gz" "${b}/unmerged.R2.fq.gz" \
        | "$SEQKIT" seq -m 50 --out-file "${b}/final.fq.gz"
    rm -f "${b}/merged.fq.gz" "${b}/unmerged.R1.fq.gz" "${b}/unmerged.R2.fq.gz"

    b_end=$(date +%s)
    local b_total_sec=$(( b_end - b_start ))
    local b_reads_out
    b_reads_out=$("$SEQKIT" stats --tabular "${b}/final.fq.gz" 2>/dev/null \
        | tail -n1 | awk '{print $4}')
    local b_pct
    b_pct=$(awk "BEGIN { if (${reads_in}+0 > 0) printf \"%.2f\", ${b_reads_out}*100/${reads_in}; else print \"N/A\" }")
    printf "pipeline_B_optimised\t%s\t%s\t%s\t%s\n" \
        "$b_total_sec" "$reads_in" "$b_reads_out" "$b_pct" \
        >> "$results_tsv"
    log_done "Pipeline B: ${b_total_sec}s  reads_in=${reads_in}  reads_out=${b_reads_out} (${b_pct}%)"

    echo ""
    echo "=== E2E Pipeline Results ==="
    column -t "$results_tsv"

    local speedup
    speedup=$(awk "BEGIN { if (${b_total_sec}+0 > 0) printf \"%.2fx\", ${a_total_sec} / ${b_total_sec}; else print \"N/A\" }")
    echo ""
    echo "Speedup (A / B): ${speedup}"
    log_done "E2E benchmark complete → ${results_tsv}"
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
cmd_report() {
    log_info "=== report ==="

    # Find most recent benchmarks/vsp2-* directory
    local bench_dir latest_dir
    bench_dir="${REPO_ROOT}/benchmarks"
    if [[ ! -d "$bench_dir" ]]; then
        log_info "No benchmarks directory found at ${bench_dir}"
        exit 1
    fi

    latest_dir=$(ls -dt "${bench_dir}"/vsp2-* 2>/dev/null | head -n1 || true)
    if [[ -z "$latest_dir" ]]; then
        log_info "No vsp2-* benchmark runs found under ${bench_dir}"
        exit 1
    fi

    log_info "Latest benchmark run: ${latest_dir}"

    local summary_tsv="${latest_dir}/summary.tsv"
    printf "benchmark\ttool\twall_sec\tpeak_rss_mb\tcpu_sec\treads_in\treads_out\tpct_change\n" \
        > "$summary_tsv"

    # Print each sub-benchmark
    for subdir in b1-dedup b2-scrub b3-merge e2e; do
        local tsv="${latest_dir}/${subdir}/results.tsv"
        if [[ ! -f "$tsv" ]]; then
            log_info "  (no results for ${subdir})"
            continue
        fi
        echo ""
        echo "--- ${subdir} ---"
        column -t "$tsv"

        # Append to summary (skip header line, prepend benchmark name)
        tail -n +2 "$tsv" | while IFS=$'\t' read -r rest; do
            printf "%s\t%s\n" "$subdir" "$rest" >> "$summary_tsv"
        done
    done

    echo ""
    echo "=== Combined Summary ==="
    column -t "$summary_tsv"
    echo ""
    log_done "Summary written to ${summary_tsv}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    setup)  cmd_setup  ;;
    dedup)  cmd_dedup  ;;
    scrub)  cmd_scrub  ;;
    merge)  cmd_merge  ;;
    e2e)    cmd_e2e    ;;
    report) cmd_report ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${1}" >&2
        cmd_help
        exit 1
        ;;
esac
