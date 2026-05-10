# VSP2 Pipeline Optimization Benchmarking

**Date**: 2026-04-04
**Branch**: `fastq-vsp2-optimization`
**Status**: Design

## Goal

Determine the fastest combination of tools for three VSP2 FASTQ processing steps — deduplication, human read removal, and paired-end merging — while maintaining comparable read retention/removal rates. All tools must fit within a 16GB RAM envelope and avoid saturating the CPU.

## Non-Goals

- GUI integration or modifying LungfishApp UI code
- Changing the production `ProcessingRecipe` in Swift
- Modifying NativeToolRunner or FASTQBatchImporter

These are deferred until benchmarks identify the optimal tool set.

## Test Dataset

| File | Size |
|------|------|
| `School001-20260216_S132_L008_R1_001.fastq.gz` | 1.8 GB |
| `School001-20260216_S132_L008_R2_001.fastq.gz` | 2.2 GB |

Location: `/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/`

Illumina NovaSeq paired-end reads, VSP2 target enrichment panel.

## Current VSP2 Recipe (6 Steps)

From `ProcessingRecipe.illuminaVSP2TargetEnrichment`:

1. **Deduplicate** — clumpify.sh (`dedupe=t`, exact PCR match)
2. **Adapter Trim** — fastp (`--detect_adapter_for_pe`)
3. **Quality Trim** — fastp (`-q 15 -W 5 --cut_right`)
4. **Human Read Scrub** — sra-human-scrubber/STAT (`scrub.sh -s -x`)
5. **Paired-End Merge** — bbmerge.sh (`minoverlap=15`)
6. **Length Filter** — seqkit (`seq -m 50`)

Steps 2, 3, and 6 are not under evaluation — only steps 1, 4, and 5.

## Benchmarks

### B1: Deduplication — clumpify.sh vs fastp --dedup

| | Tool A (current) | Tool B (candidate) |
|-|-----------------|-------------------|
| **Binary** | `bbtools/clumpify.sh` (Java) | `fastp` (C++) |
| **Command** | `clumpify.sh in=R1.fq.gz in2=R2.fq.gz out=dedup.R1.fq.gz out2=dedup.R2.fq.gz dedupe=t subs=0 reorder groups=auto pigz=t zl=4 -Xmx9g threads=N` | `fastp -i R1.fq.gz -I R2.fq.gz -o dedup.R1.fq.gz -O dedup.R2.fq.gz --dedup -A -j dedup.json -h /dev/null -w N` |
| **Memory** | `-Xmx9g` (9 GB Java heap) | Internal hash table, typically 4–8 GB |
| **Notes** | `-A` on fastp disables adapter trimming so we isolate dedup only. `-j`/`-h` capture stats. |

**Metrics**: Wall time, peak RSS, input read count, output read count, % removed.

### B2: Human Read Removal — sra-human-scrubber vs Deacon

| | Tool A (current) | Tool B (candidate) |
|-|-----------------|-------------------|
| **Binary** | `scrubber/scripts/scrub.sh` | `deacon` (Rust) |
| **Database** | `human_filter.db.20250916v2` (973 MB) | `panhuman-1.k31w15.idx` (3.3 GB) |
| **Command** | `scrub.sh -i input.fq -o scrubbed.fq -d $DB_PATH -p N -s -x` | `deacon filter -d $DEACON_IDX R1.fq.gz R2.fq.gz -o scrubbed.R1.fq.gz -O scrubbed.R2.fq.gz -t N` |
| **Memory** | ~2 GB RSS (memory-mapped DB) | ~5 GB (index loaded to RAM) |
| **Notes** | STAT requires plain-text input (decompress first). Deacon reads gzip natively. Deacon `-d` flag = depletion mode (discard matching/human reads, keep non-human). Index is a positional argument. |

**Input**: Output from the dedup step (either tool's output — use current clumpify output for both to keep the comparison fair).

**Metrics**: Wall time, peak RSS, input read count, output read count, % human reads removed.

**Important**: STAT operates on interleaved input (`-s` flag) and removes both reads in a pair if either matches. Verify that Deacon's paired-end mode has equivalent pair-aware behavior.

### B3: Paired-End Merge — bbmerge.sh vs fastp --merge

| | Tool A (current) | Tool B (candidate) |
|-|-----------------|-------------------|
| **Binary** | `bbtools/bbmerge.sh` (Java) | `fastp` (C++) |
| **Command** | `bbmerge.sh in=interleaved.fq out=merged.fq outu1=unmerged.R1.fq outu2=unmerged.R2.fq minoverlap=15 threads=N` | `fastp -i R1.fq.gz -I R2.fq.gz --merge --merged_out merged.fq.gz --out1 unmerged.R1.fq.gz --out2 unmerged.R2.fq.gz --overlap_len_require 15 -A -G -Q -L -j merge.json -h /dev/null -w N` |
| **Memory** | `-Xmx9g` | Streaming, <1 GB |
| **Notes** | fastp flags `-A -G -Q -L` disable adapter trim, quality filter, quality trim, and length filter to isolate merge behavior. bbmerge expects interleaved input; fastp expects separate R1/R2. |

**Input**: Output from the human scrub step.

**Metrics**: Wall time, peak RSS, merged read count, unmerged read count, % merged. Also compare merged read length distributions (mean, median, N50).

### E2E: Full Pipeline Comparison

Run the complete 6-step VSP2 recipe twice:

**E2E-A (current)**: clumpify → fastp trim → fastp quality → STAT scrub → bbmerge → seqkit filter

**E2E-B (optimized)**: Best dedup tool → fastp trim → fastp quality → best scrub tool → best merge tool → seqkit filter

If fastp wins multiple steps, combine them into fewer fastp invocations where possible (e.g., dedup + adapter trim + quality trim in one pass).

**Metrics**: Total wall time, total peak RSS, final read count, final merged read count.

## Resource Constraints

All benchmarks must respect a 16GB laptop envelope:

| Tool | Memory Limit | Mechanism |
|------|-------------|-----------|
| clumpify.sh | 9 GB | `-Xmx9g` Java heap |
| fastp (any mode) | ~4–8 GB | Internal; no explicit cap needed |
| sra-human-scrubber | ~2 GB | Memory-mapped DB |
| deacon filter | ~5 GB | Index loaded to RAM |
| bbmerge.sh | 9 GB | `-Xmx9g` Java heap |

**Thread count**: Use performance cores only — `$(sysctl -n hw.performancecores)`. On Apple Silicon this is typically 6–8 P-cores, leaving efficiency cores for system tasks. If `hw.performancecores` is unavailable, fall back to `$(( $(sysctl -n hw.ncpu) / 2 ))`.

## Tool Installation & Database Setup

### Already Available

| Tool | Location | Version |
|------|----------|---------|
| fastp | `Sources/LungfishWorkflow/Resources/Tools/fastp` | 1.1.0 |
| clumpify.sh | `Sources/LungfishWorkflow/Resources/Tools/bbtools/clumpify.sh` | bundled |
| bbmerge.sh | `Sources/LungfishWorkflow/Resources/Tools/bbtools/bbmerge.sh` | bundled |
| scrub.sh | `Sources/LungfishWorkflow/Resources/Tools/scrubber/scripts/scrub.sh` | bundled |
| pigz | `Sources/LungfishWorkflow/Resources/Tools/pigz` | bundled |
| seqkit | `Sources/LungfishWorkflow/Resources/Tools/seqkit` | bundled |

### To Install

**Deacon**: Install via `cargo install deacon` (requires Rust 1.88+) or `conda install -c bioconda deacon`. Record installed version.

**Deacon index**: Download `panhuman-1.k31w15.idx` (3.3 GB) to `~/Library/Application Support/Lungfish/databases/deacon/`. Create a `manifest.json` matching the DatabaseRegistry pattern:

```json
{
  "id": "deacon",
  "displayName": "Deacon Human Pangenome Index",
  "tool": "deacon",
  "version": "panhuman-1",
  "filename": "panhuman-1.k31w15.idx",
  "description": "Minimizer index for human read depletion. Human pangenome plus bacterial and viral sequences. k=31, w=15, ~410M minimizers.",
  "sourceUrl": "https://github.com/bede/deacon"
}
```

## Benchmark Script

Single script at `scripts/benchmark-vsp2.sh` with subcommands:

```
./scripts/benchmark-vsp2.sh setup       # Install deacon, download panhuman-1 index
./scripts/benchmark-vsp2.sh dedup       # B1: clumpify vs fastp --dedup
./scripts/benchmark-vsp2.sh scrub       # B2: STAT vs deacon
./scripts/benchmark-vsp2.sh merge       # B3: bbmerge vs fastp --merge
./scripts/benchmark-vsp2.sh e2e         # Full pipeline: current vs optimized
./scripts/benchmark-vsp2.sh report      # Generate summary table
```

### Configuration Variables (top of script)

```bash
R1="/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R1_001.fastq.gz"
R2="/Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R2_001.fastq.gz"
TOOLS="$(cd "$(dirname "$0")/../Sources/LungfishWorkflow/Resources/Tools" && pwd)"
DEACON_DB="$HOME/Library/Application Support/Lungfish/databases/deacon/panhuman-1.k31w15.idx"
SCRUBBER_DB="$(cd "$(dirname "$0")/../Sources/LungfishWorkflow/Resources/Databases/human-scrubber" && pwd)/human_filter.db.20250916v2"
THREADS="$(sysctl -n hw.performancecores 2>/dev/null || echo $(( $(sysctl -n hw.ncpu) / 2 )))"
WORKDIR="benchmarks/vsp2-$(date +%Y%m%d)"
```

### Timing and Read Counting

Each tool run is wrapped with:
```bash
/usr/bin/time -l <command> 2> timing.txt
$TOOLS/seqkit stats --tabular <output> > readcounts.tsv
```

Parse wall time, peak RSS (maximum resident set size), and user+system CPU time from `/usr/bin/time -l` output. Parse read counts from seqkit stats.

### Output Structure

```
benchmarks/vsp2-YYYYMMDD/
├── B1-dedup/
│   ├── clumpify/
│   │   ├── output.R1.fq.gz
│   │   ├── output.R2.fq.gz
│   │   ├── timing.txt
│   │   └── readcounts.tsv
│   ├── fastp/
│   │   ├── output.R1.fq.gz
│   │   ├── output.R2.fq.gz
│   │   ├── dedup.json
│   │   ├── timing.txt
│   │   └── readcounts.tsv
│   └── results.tsv
├── B2-scrub/
│   ├── stat/
│   ├── deacon/
│   └── results.tsv
├── B3-merge/
│   ├── bbmerge/
│   ├── fastp/
│   └── results.tsv
├── E2E/
│   ├── current/
│   ├── optimized/
│   └── results.tsv
└── summary.tsv
```

### Results TSV Format

Each `results.tsv`:
```
tool	wall_sec	peak_rss_mb	cpu_sec	reads_in	reads_out	pct_removed
clumpify	342	9200	1850	48000000	42000000	12.5
fastp	87	5100	620	48000000	41800000	12.9
```

`summary.tsv` aggregates all benchmarks with an additional `benchmark` column.

## Success Criteria for Switching a Tool

A candidate tool replaces the current tool if ALL of the following hold:

1. **Speed**: >10% wall time reduction
2. **Comparable results**: Read retention/removal within 5% of current tool
3. **Memory**: Peak RSS < 12 GB (leaves 4 GB headroom on 16 GB machine)
4. **Correctness**: Output is valid FASTQ, paired reads stay paired (verify with `seqkit pair`)
5. **Pair-awareness**: For human scrub, verify both reads in a pair are removed when either matches (same behavior as STAT's `-s` flag)

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Deacon's paired-end depletion semantics differ from STAT | Verify by comparing per-read removal decisions on a small subset; check Deacon docs for pair-aware mode |
| fastp --dedup hash table exceeds 12 GB on large datasets | Monitor peak RSS; if exceeded, fastp is disqualified for dedup on 16 GB machines |
| Test dataset not representative of all VSP2 samples | This is a single-sample benchmark; production decision may require additional samples |
| NVMe remote volume I/O variance | Run each benchmark twice; use the faster run (eliminates cold-cache penalty on first run) |
| Deacon index download fails or is slow (3.3 GB) | Script includes retry logic and checksum verification |

## Future Integration (Post-Benchmark)

If benchmarks identify faster tools, integration involves:

1. Register winning tools in `NativeTool` enum and `NativeToolRunner`
2. Add Deacon database to `DatabaseRegistry` (manifest already prepared)
3. Update `ProcessingRecipe.illuminaVSP2TargetEnrichment` step definitions
4. Update `FASTQBatchImporter` step execution methods
5. Update CLI `--recipe vsp2` to use new tools
6. If fastp can combine dedup + trim + quality in one pass, reduce recipe steps from 6 to 4
