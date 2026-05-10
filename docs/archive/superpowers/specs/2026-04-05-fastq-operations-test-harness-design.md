# Sub-project 1: FASTQ Operations Test Harness & Shared Infrastructure Audit

**Date:** 2026-04-05
**Branch:** `fastq-operations-preview`
**Scope:** Test framework, shared code audit, CLI gaps, fixed trim bug, materialization CLI

---

## 1. Goal

Build a reusable test framework that can verify any FASTQ derivative operation's round-trip (create → preview → materialize), audit and harden the shared infrastructure, fix known bugs, and fill CLI gaps — so that Sub-projects 2 and 3 can systematically test all ~20 operations against a solid foundation.

---

## 2. Test Framework Architecture

### 2.1 Two Test Layers

**Unit tests** (`Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`)
- Mock `NativeToolRunner` at the boundary to test preview generation, trim extraction, and materialization logic without requiring external tools.
- Use synthetic FASTQ data written to temp directories.
- Fast, CI-friendly, no tool dependencies.

**Integration tests** (`Tests/LungfishIntegrationTests/FASTQOperationIntegrationTests.swift`)
- Run real tools (seqkit, fastp, bbtools, cutadapt) against SARS-CoV-2 fixtures.
- Each test follows the canonical round-trip pattern (see §2.2).
- Require tools to be installed; skip gracefully if missing.

### 2.2 Canonical Round-Trip Test Pattern

Every operation test follows this sequence:

```
1. Prepare source bundle (from fixtures or synthetic data)
2. Create derivative via FASTQDerivativeService.createDerivative()
3. Assert preview.fastq exists, is valid FASTQ, has >0 reads
4. Assert manifest payload type matches expected (.subset / .trim / .full / etc.)
5. Materialize via `lungfish fastq materialize` CLI
6. Assert materialized output is valid FASTQ
7. Assert semantic correctness (e.g., trimmed reads are shorter, subsets contain only matching IDs)
```

### 2.3 Shared Test Utilities

`FASTQOperationTestHelper` — a struct (not protocol) in a shared test support file:

| Method | Purpose |
|--------|---------|
| `assertPreviewValid(bundleURL:)` | Checks `preview.fastq` exists, has >0 parseable FASTQ reads |
| `assertMaterializationRoundTrip(bundleURL:outputDir:)` | Runs `lungfish fastq materialize`, checks output is valid FASTQ |
| `assertPayloadType(bundleURL:expected:)` | Reads manifest, checks payload enum case matches |
| `assertTrimPositionsValid(bundleURL:)` | For trim ops: checks TSV has correct columns, non-empty rows, valid offsets |
| `assertSubsetIDsValid(bundleURL:)` | For subset ops: checks read ID list exists, IDs appear in root FASTQ |
| `createTempBundle(from:)` | Creates a temporary .lungfishfastq bundle from fixture FASTQ files |
| `writeSyntheticFASTQ(to:readCount:readLength:)` | Writes deterministic synthetic FASTQ for unit tests |

---

## 3. Shared Infrastructure Audit

### 3.1 `writePreviewFASTQ`

**Location:** `FASTQDerivativeService.swift:4150`
**Current behavior:** Tries `seqkit head -n 1000`, falls back to Swift FASTQReader/FASTQWriter.
**Audit focus:** Verify the source URL passed to this function is the *post-operation* output for trim operations, not the root FASTQ. This is the suspected cause of the fixed trim bug.

**Tests:**
- Unit: Write known FASTQ → call writePreviewFASTQ → verify output has ≤1000 reads and content matches source.
- Integration: After fixedTrim, verify preview reads are trimmed (shorter than originals by expected amount).

### 3.2 `extractTrimPositions`

**Location:** `FASTQDerivativeService.swift:4207`
**Current behavior:** Diffs original vs trimmed FASTQ by finding substring positions. Handles PE interleaved data with positional keys.
**Audit focus:** Verify correctness for all trim modes — quality trim produces variable-length trims, fixed trim produces uniform trims, adapter trim depends on adapter location.

**Tests:**
- Unit: Synthetic FASTQ with known sequences → apply manual trim → verify extracted positions match expected values.
- Specifically test edge cases: read trimmed to 0 length (should be skipped), read unchanged (trimStart=0, trimEnd=len), trim from both ends.

### 3.3 `materializeDatasetFASTQ` → CLI Refactor

**Location:** `FASTQDerivativeService.swift:1876`
**Current behavior:** In-process Swift code that reads manifest and applies payload-specific logic (subset via seqkit grep, trim via position extraction, full via file copy).
**Refactor:** Replace with CLI invocation of `lungfish fastq materialize`. All materialization goes through the CLI — no in-process fast path.

**Tests:**
- Integration: For each payload type (subset, trim, full, fullPaired, orientMap), create a derivative then materialize via CLI, verify output correctness.

---

## 4. CLI Gap Audit & New Subcommands

### 4.1 Missing Subcommands

| Operation | CLI Subcommand | Tool Backend | Arguments |
|-----------|---------------|--------------|-----------|
| `searchText` | `lungfish fastq search-text` | seqkit grep | `--query`, `--field` (id/desc), `--regex` |
| `searchMotif` | `lungfish fastq search-motif` | seqkit locate/grep | `--pattern`, `--regex` |
| `orient` | `lungfish fastq orient` | bbmap reformat.sh | `--reference`, `--word-length`, `--db-mask` |
| `humanReadScrub` | `lungfish fastq scrub-human` | bbmap/kraken2 | `--database-id`, `--remove-reads` |
| `sequencePresenceFilter` | `lungfish fastq sequence-filter` | bbduk | `--sequence`, `--fasta-path`, `--keep-matched`, etc. |

### 4.2 New Materialize Subcommand

```
lungfish fastq materialize <bundle-path> -o <output-path> [--temp-dir <dir>]
```

- Reads the derived bundle manifest
- Resolves root FASTQ
- Applies payload-specific materialization (subset/trim/full/orient)
- Writes materialized FASTQ to output path
- Exits with appropriate error codes for missing manifest, missing root, etc.

### 4.3 All Subcommands Follow Existing Pattern

Each is an `AsyncParsableCommand` with:
- Standard input/output path arguments
- Tool-specific flags matching `FASTQDerivativeRequest` parameters
- BBTools environment setup (Java, PATH) where needed
- Delegates to `NativeToolRunner` for execution

---

## 5. Fixed Trim Bug

### 5.1 Symptom
Document Inspector shows correct trim statistics, but the viewport does not display a `preview.fastq` file.

### 5.2 Hypothesis
For trim operations, `writePreviewFASTQ` is called with the root (untrimmed) FASTQ instead of the post-trim output, OR the preview is written but to the wrong location / with the wrong filename.

### 5.3 TDD Approach
1. Write a failing integration test: `testFixedTrimPreviewContainsTrimmedReads`
   - Apply `fixedTrim(from5Prime: 10, from3Prime: 10)` to SARS-CoV-2 reads
   - Assert `preview.fastq` exists in the derived bundle
   - Assert every read in preview is exactly 20bp shorter than the corresponding original
2. Investigate the failure to identify root cause
3. Fix the code path
4. Verify the test passes

### 5.4 Possible Fix Locations
- The dispatch logic in `createDerivative()` around lines 679–746 where preview is written
- The trim operation handler that may not be passing the trimmed output to `writePreviewFASTQ`

---

## 6. GUI Wiring: Materialization via CLI

`FASTQDerivativeService.materializeDatasetFASTQ()` must be refactored to:

1. Build a `lungfish fastq materialize <bundlePath> -o <outputPath>` command
2. Execute via `NativeToolRunner`
3. Parse exit code and stderr for error reporting
4. Return the output URL on success

This replaces the in-process branching logic for subset/trim/full/fullPaired/orient payloads. Demux materialization (`.demuxedVirtual`, `.demuxGroup`) is complex and deferred to Sub-project 3; it remains in-process for now. The CLI command contains all non-demux logic, making it debuggable from Terminal.

The `exportMaterializedFASTQ()` method similarly delegates to the CLI.

---

## 7. Deliverables Checklist

1. **`FASTQOperationTestHelper`** — shared assertion utilities in test support file
2. **Unit tests** — mock-based tests for writePreviewFASTQ, extractTrimPositions, materialization logic
3. **Integration tests** — real-tool round-trip tests for subset, trim, full, orient payload types
4. **`lungfish fastq materialize` CLI** — replaces in-process materialization entirely
5. **5 missing CLI subcommands** — search-text, search-motif, orient, scrub-human, sequence-filter
6. **Fixed trim bug fix** — TDD: failing test → root cause → fix
7. **GUI refactor** — `materializeDatasetFASTQ()` calls CLI instead of in-process logic

---

## 8. Out of Scope

- Individual operation correctness testing for all 19 operations (Sub-projects 2 & 3)
- Performance benchmarking
- GUI/viewport changes beyond materialization wiring
- Demux-specific materialization (complex, deferred to Sub-project 3)
