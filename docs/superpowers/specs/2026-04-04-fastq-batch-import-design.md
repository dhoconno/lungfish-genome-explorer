# FASTQ Batch Import with Memory Safety

**Date**: 2026-04-04
**Status**: Approved
**Branch**: `fastq-import-fix`

## Problem

Drag-and-drop import of ~52 paired-end FASTQ samples (2-10 GB compressed per pair) with the VSP2 recipe causes the app to silently quit after processing only a few samples. Root causes identified:

1. **Intermediate file accumulation**: `runVSP2RecipeWithDelayedInterleave` creates 6 uncompressed intermediate R1/R2 files per sample (potentially 60-300 GB of temp per sample) without cleaning up between steps.
2. **Java heap pressure**: Each clumpify invocation allocates 80% of physical RAM to JVM heap. Combined with the app's own memory and Foundation object accumulation, this triggers macOS jetsam.
3. **No autoreleasepool boundaries**: The entire multi-sample pipeline runs in `Task.detached` without draining Foundation/bridging objects between samples.
4. **Unbounded pipe capture**: `NativeToolRunner.runProcess` calls `readDataToEndOfFile()` on stderr, capturing BBTools' verbose progress output entirely in RAM.
5. **In-process fragility**: The pipeline runs inside the GUI app process — if any sample's processing triggers OOM, the entire app dies.

## Solution

A new `lungfish import fastq` CLI command that processes samples sequentially with aggressive memory management. The GUI spawns this command as a child process, keeping the app alive even if the import process is killed.

## CLI Interface

```
lungfish import fastq <input-dir-or-files...> \
    --project <path.lungfish> \
    --recipe vsp2 \
    [--platform illumina] \
    [--quality-binning illumina4] \
    [--threads auto] \
    [--log-dir <path>] \
    [--dry-run]
```

### Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `input` | Yes | — | Directory to scan or explicit file paths |
| `--project` | Yes | — | Path to `.lungfish` project directory |
| `--recipe` | No | `none` | Recipe name: `vsp2`, `wgs`, `amplicon`, `hifi`, `none` |
| `--platform` | No | `illumina` | Sequencing platform hint |
| `--quality-binning` | No | `illumina4` | Binning scheme: `illumina4`, `eightLevel`, `none` |
| `--threads` | No | `auto` | Thread count for tools (auto = all cores) |
| `--log-dir` | No | `<project>/.tmp/import-logs/` | Directory for per-sample log files |
| `--dry-run` | No | `false` | List detected pairs and exit |

### Pair Detection

Reuses existing `groupFASTQByPairs` logic from `FASTQImportConfiguration.swift`:
- Patterns: `_R1_001`/`_R2_001`, `_R1`/`_R2`, `_1`/`_2`
- Sample name derived by stripping paired suffixes and extensions
- Unpaired files treated as single-end

### Recipe Resolution

| `--recipe` value | Maps to |
|------------------|---------|
| `vsp2` | `ProcessingRecipe.illuminaVSP2TargetEnrichment` |
| `wgs` | `ProcessingRecipe.illuminaWGS` |
| `amplicon` | `ProcessingRecipe.targetedAmplicon` |
| `hifi` | `ProcessingRecipe.pacbioHiFi` |
| `none` | No recipe — clumpify + compress only |

## Pipeline Architecture

### Per-Sample Processing (Sequential)

```
For each paired sample (strictly one at a time):
  1. Validate inputs exist and are readable
  2. Create workspace (same-volume temp dir via itemReplacementDirectory)
  3. Run recipe steps with intermediate cleanup:
     a. Execute step N
     b. Delete step N-1 intermediate files
     c. Repeat until all steps complete
  4. Clumpify + compress final output
  5. Create .lungfishfastq bundle in project directory
  6. Write metadata sidecars (manifest.json, .lungfish-meta.json)
  7. Compute and cache FASTQ statistics
  8. Remove workspace directory
  9. Emit structured log entry
  10. autoreleasepool barrier before next sample
```

### Memory Safety Measures

1. **Intermediate file cleanup between recipe steps**: After each VSP2 step completes and the output is verified, delete the input files from the previous step. Only the current step's output files remain on disk at any time.

2. **`autoreleasepool` per sample**: Wrap each sample's entire processing block in `autoreleasepool { }` to drain Foundation bridging objects (URL, Data, String) between samples.

3. **Java heap reduction**: Cap JVM heap at 60% of physical memory (down from 80%), leaving headroom for the OS, file cache, and the import process itself.

4. **Bounded stderr capture**: Limit captured tool stderr to the last 64 KB. BBTools writes verbose progress lines to stderr; we only need the tail for error diagnosis.

5. **Out-of-process execution**: The GUI spawns the CLI as a child process. If jetsam kills the import process, the app survives and reports the failure. The user can restart the import (it will skip already-imported samples via bundle existence checks).

### Threading Model

- Each tool invocation uses all available cores (`ProcessInfo.processInfo.activeProcessorCount`)
- `clumpify.sh`: `threads=<N>`, `pigz=t`
- `fastp`: `-w <N>`
- Only one sample is processed at a time — no cross-sample parallelism
- This maximizes per-sample throughput while keeping memory bounded

## Structured Logging

### Machine-readable (stdout, JSON lines)

```json
{"event":"import_start","sample_count":52,"recipe":"Illumina VSP2 Target Enrichment","timestamp":"2026-04-04T10:00:00Z"}
{"event":"sample_start","sample":"School001-20260216","index":1,"total":52,"r1":"School001-20260216_S132_L008_R1_001.fastq.gz","r2":"School001-20260216_S132_L008_R2_001.fastq.gz"}
{"event":"step_start","sample":"School001-20260216","step":"deduplicate","step_index":1,"total_steps":6}
{"event":"step_complete","sample":"School001-20260216","step":"deduplicate","duration_s":45.2}
{"event":"step_start","sample":"School001-20260216","step":"adapter_trim","step_index":2,"total_steps":6}
{"event":"step_complete","sample":"School001-20260216","step":"adapter_trim","duration_s":23.1}
{"event":"sample_complete","sample":"School001-20260216","bundle":"School001-20260216.lungfishfastq","duration_s":312.5,"original_bytes":5368709120,"final_bytes":1073741824}
{"event":"sample_skip","sample":"School002-20260216","reason":"bundle already exists"}
{"event":"import_complete","completed":52,"skipped":0,"failed":0,"total_duration_s":16250.0}
```

### Human-readable (stderr)

```
[1/52] School001-20260216
  → Deduplicate... done (45s)
  → Adapter trim... done (23s)
  → Quality trim... done (18s)
  → Human read scrub... done (120s)
  → Paired-end merge... done (35s)
  → Length filter... done (8s)
  → Clumpify + compress... done (63s)
  ✓ Created School001-20260216.lungfishfastq (5.0 GB → 1.0 GB, saved 80%)
```

### Per-sample log files

Written to `--log-dir`, one file per sample:
- `School001-20260216.log` — full tool stdout/stderr for each step
- Preserved for debugging if a sample fails

## GUI Integration

### Drag-and-Drop Path

The existing `FASTQIngestionService.ingestAndBundle` flow changes:

**Before** (current, broken):
1. GUI receives drop
2. Shows import config sheet
3. User clicks Import
4. `Task.detached` runs pipeline inline in app process
5. App crashes under memory pressure

**After** (new):
1. GUI receives drop
2. Shows import config sheet (same UI)
3. User clicks Import
4. App constructs `lungfish import fastq` command with matching arguments
5. App spawns CLI as child process via `Process` with line-by-line stdout pipe reading (NOT `NativeToolRunner.runProcess`, which buffers fully)
6. App parses JSON lines from CLI stdout for progress as they arrive
7. OperationCenter displays progress per sample/step
8. If CLI exits non-zero, app reports which sample failed
9. App stays alive regardless of CLI process fate

### Skip-If-Exists

Both CLI and GUI check for existing `.lungfishfastq` bundles in the project directory before processing each sample. This provides basic resumability: if the import is interrupted, restarting it skips already-completed samples.

## Test Strategy

### Unit Tests (LungfishCLITests)

| Test | Validates |
|------|-----------|
| `testPairDetectionFromDirectory` | R1/R2 matching for Illumina naming patterns |
| `testPairDetectionMixedPatterns` | `_R1_001`, `_R1`, `_1` patterns in same directory |
| `testSampleNameDerivation` | Strip suffixes to get clean sample name |
| `testRecipeResolution` | `--recipe vsp2` resolves to correct ProcessingRecipe |
| `testDryRunOutput` | Dry-run lists pairs without processing |
| `testArgumentParsing` | Required/optional args, defaults |
| `testSkipExistingBundles` | Samples with existing bundles are skipped |

### Integration Tests (LungfishIntegrationTests)

| Test | Validates |
|------|-----------|
| `testSingleSampleVSP2Import` | Full pipeline with test fixtures produces valid bundle |
| `testIntermediateCleanup` | Temp files don't accumulate between recipe steps |
| `testBundleStructure` | Output bundle contains expected files and metadata |
| `testStructuredLogFormat` | JSON log lines parse correctly |
| `testFailedSampleContinues` | Pipeline continues to next sample after failure |
| `testWorkspaceCleanupOnFailure` | Temp dir removed even on error |
| `testCancellation` | `SIGTERM` / `SIGINT` triggers cleanup |

### Memory/Resource Tests

| Test | Validates |
|------|-----------|
| `testAutoreleasepoolBoundaries` | No leaked temp directories after processing |
| `testJavaHeapCapping` | Clumpify uses ≤60% of physical memory |
| `testBoundedStderrCapture` | Stderr output is truncated to 64KB |

## File Changes

### New Files

| File | Module | Purpose |
|------|--------|---------|
| `Sources/LungfishCLI/Commands/ImportFastqCommand.swift` | LungfishCLI | CLI command implementation |
| `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` | LungfishWorkflow | Core batch import logic (shared by CLI and GUI) |
| `Tests/LungfishCLITests/ImportFastqCommandTests.swift` | LungfishCLITests | Unit tests |
| `Tests/LungfishIntegrationTests/FASTQBatchImportTests.swift` | LungfishIntegrationTests | Integration tests |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/LungfishCLI/Commands/ImportCommand.swift` | Add `FastqSubcommand` to subcommands list |
| `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift` | Reduce Java heap cap from 80% to 60%; add intermediate cleanup hooks |
| `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` | Add bounded stderr capture option (64KB ring buffer) |
| `Sources/LungfishApp/Services/FASTQIngestionService.swift` | Add CLI subprocess spawn path (streaming `Process` with line-by-line stdout parsing) as alternative to inline processing |

## Scope Boundaries

### In Scope

- `lungfish import fastq` CLI command with pair detection, recipe execution, and memory safety
- Sequential one-at-a-time processing with all cores per sample
- Intermediate file cleanup between recipe steps
- autoreleasepool boundaries between samples
- Bounded stderr capture in NativeToolRunner
- Java heap reduction (80% → 60%)
- Structured JSON logging (stdout) + human progress (stderr) + per-sample log files
- GUI integration: spawn CLI as subprocess, parse progress, display in OperationCenter
- Skip-if-exists for basic resumability
- TDD test suite (unit + integration)

### Out of Scope

- True resumability with checkpoint files
- Progress percentage within individual tool runs (only step-level granularity)
- Custom recipe files via `--recipe <path.json>`
- Parallel sample processing
- GUI import config sheet redesign
