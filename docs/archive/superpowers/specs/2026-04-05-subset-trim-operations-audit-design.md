# Sub-project 2: Subset + Trim Operations Audit

**Date:** 2026-04-05
**Branch:** `fastq-operations-preview`
**Scope:** Integration tests and bug fixes for 11 virtual-bundle FASTQ operations
**Prerequisite:** Sub-project 1 (test framework, trim preview fix, materialization CLI)

---

## 1. Goal

Systematically test all 11 subset and trim operations through the full round-trip (create derivative → verify preview.fastq → verify payload → materialize → verify output), using the test framework built in Sub-project 1. Fix any bugs discovered.

---

## 2. Operations In Scope

### Subset Operations (7)

These produce a `read-ids.txt` file and a `preview.fastq`. Materialization extracts matching reads from the root FASTQ via seqkit grep.

| Operation | Enum Case | Tool | Key Assertion |
|-----------|-----------|------|---------------|
| Subsample by Proportion | `subsampleProportion(Double)` | seqkit sample | Output count within tolerance of proportion x input |
| Subsample by Count | `subsampleCount(Int)` | seqkit sample | Output count = requested count |
| Filter by Read Length | `lengthFilter(min:max:)` | seqkit seq | All output reads within [min, max] bounds |
| Extract by ID | `searchText(query:field:regex:)` | seqkit grep | All output reads match query in specified field |
| Extract by Motif | `searchMotif(pattern:regex:)` | seqkit grep --by-seq | All output reads contain motif in sequence |
| Contaminant Filter | `contaminantFilter(mode:...)` | bbduk | Reads matching contaminant ref are removed |
| Adapter Filter | `sequencePresenceFilter(...)` | bbduk | Filtered reads match/don't match target sequence |

### Trim Operations (4)

These produce a `trim-positions.tsv` file and a `preview.fastq` (fixed in SP1). Materialization applies trim positions to root FASTQ reads.

| Operation | Enum Case | Tool | Key Assertion |
|-----------|-----------|------|---------------|
| Quality Trim | `qualityTrim(threshold:windowSize:mode:)` | fastp | Output reads ≤ original length, positions valid |
| Adapter Removal | `adapterTrim(mode:sequence:...)` | fastp | Output reads ≤ original length, adapter removed |
| Trim Fixed Bases | `fixedTrim(from5Prime:from3Prime:)` | fastp | Output reads shorter by exactly N+M bases |
| PCR Primer Trimming | `primerRemoval(configuration:)` | cutadapt/bbduk | Output reads ≤ original length, primer removed |

---

## 3. Test Strategy

### 3.1 Test Location

Tests that call `FASTQDerivativeService.createDerivative()` go in `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` (which can import `LungfishApp`). Tests that only exercise materialization via `FASTQCLIMaterializer` go in `Tests/LungfishIntegrationTests/FASTQOperationIntegrationTests.swift`. All are integration tests requiring real tools.

### 3.2 Canonical Test Pattern

Every test follows the round-trip established in SP1:

```
1. Create root bundle with synthetic FASTQ (uncompressed, deterministic reads)
2. Call FASTQDerivativeService.createDerivative(from:request:progress:)
3. Assert preview.fastq exists and is valid (>0 parseable reads)
4. Assert payload type matches expected (.subset or .trim)
5. Assert payload file is valid (read-ids.txt or trim-positions.tsv)
6. Materialize via FASTQCLIMaterializer
7. Assert materialized output is valid FASTQ
8. Assert operation-specific semantic correctness
```

### 3.3 Synthetic Data Design

Use `FASTQOperationTestHelper.writeSyntheticFASTQ()` for most tests. For operations that need specific data properties:

- **lengthFilter**: Write reads with varying lengths (50bp, 100bp, 150bp, 200bp)
- **searchText**: Write reads with specific ID patterns (e.g., "sample1_read1", "sample2_read1")
- **searchMotif**: Write reads with a known motif embedded in some reads
- **adapterTrim**: Write reads with a known adapter sequence appended
- **primerRemoval**: Write reads with a known primer sequence prepended
- **sequencePresenceFilter**: Write reads with a known adapter in some reads

### 3.4 Access Constraint

`LungfishIntegrationTests` does NOT depend on `LungfishApp`, so `FASTQDerivativeService` is unavailable. Tests must either:
- Use `FASTQCLIMaterializer` from `LungfishWorkflow` for materialization (already done in SP1 tests)
- Create synthetic derived bundles with known payloads to test materialization in isolation

For full round-trip tests that need `createDerivative`, they go in `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` instead (which CAN import `LungfishApp`).

---

## 4. Test Specifications Per Operation

### 4.1 Subsample by Count
- Input: 100 reads, 100bp each
- Request: `.subsampleCount(20)`
- Assert: materialized output has exactly 20 reads, all 100bp

### 4.2 Subsample by Proportion
- Input: 100 reads, 100bp each
- Request: `.subsampleProportion(0.25)`
- Assert: materialized output has ~25 reads (tolerance: 15-35 due to randomness)

### 4.3 Length Filter
- Input: 25 reads at 50bp, 25 at 100bp, 25 at 150bp, 25 at 200bp
- Request: `.lengthFilter(min: 80, max: 160)`
- Assert: materialized output has exactly 50 reads (the 100bp and 150bp ones)

### 4.4 Search Text (ID)
- Input: 50 reads with IDs "alpha_1"..."alpha_25" and "beta_1"..."beta_25"
- Request: `.searchText(query: "alpha", field: .identifier, regex: false)`
- Assert: materialized output has exactly 25 reads, all with "alpha" in ID

### 4.5 Search Motif
- Input: 50 reads, 25 containing "AGATCGGAAG" embedded at position 50, 25 without
- Request: `.searchMotif(pattern: "AGATCGGAAG", regex: false)`
- Assert: materialized output has exactly 25 reads, all containing the motif

### 4.6 Contaminant Filter
- Input: 50 reads, 100bp, synthetic (no actual PhiX contamination)
- Request: `.contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: 31, hammingDistance: 1)`
- Assert: payload is subset, read-ids.txt exists, preview.fastq exists
- Assert: materialized output has reads (most/all should pass since synthetic data won't match PhiX)
- Note: requires bbduk + BBTools environment

### 4.7 Sequence Presence Filter
- Input: 50 reads, 25 with adapter "AGATCGGAAGAGC" at 3' end, 25 without
- Request: `.sequencePresenceFilter(sequence: "AGATCGGAAGAGC", keepMatched: false, ...)`
- Assert: payload is subset, read-ids.txt exists, preview.fastq exists
- Assert: materialized output has ~25 reads (those without the adapter)
- Note: requires bbduk + BBTools environment

### 4.8 Quality Trim
- Input: 50 reads, 100bp, uniform high-quality scores
- Request: `.qualityTrim(threshold: 20, windowSize: 4, mode: .slidingWindow)`
- Assert: trim positions exist, all reads present (high-quality reads may not be trimmed)
- Assert: preview.fastq exists and is valid

### 4.9 Adapter Trim
- Input: 50 reads, 100bp, with Illumina universal adapter appended to some
- Request: `.adapterTrim(mode: .autoDetect, sequence: nil, ...)`
- Assert: trim positions exist, trimmed reads ≤ original length
- Assert: preview.fastq contains trimmed reads

### 4.10 Fixed Trim (already tested in SP1, expand coverage)
- Already has `testFixedTrimPreviewReadsAreTrimmed` and `testFixedTrimRoundTrip`
- Add: materialization round-trip via `FASTQCLIMaterializer` to verify trim positions are correctly applied

### 4.11 Primer Removal
- Input: 50 reads with known primer "GTTTCCCAGTCACGACG" prepended
- Request: `.primerRemoval(configuration: ...)` with the primer sequence
- Assert: trim positions exist, trimmed reads shorter by primer length
- Assert: preview.fastq exists

---

## 5. Regression Suite Design

All round-trip tests use a consistent naming convention so the entire FASTQ operations regression suite can be run with a single filter:

```bash
# Run all FASTQ operation round-trip tests
swift test --filter "FASTQOperationRoundTripTests"

# Run all FASTQ materialization integration tests
swift test --filter "FASTQOperationIntegrationTests"

# Run both suites together
swift test --filter "FASTQOperation"
```

Test method names follow the pattern `test<OperationName>RoundTrip` (e.g., `testSubsampleCountRoundTrip`, `testQualityTrimRoundTrip`). This makes it easy to run a single operation's test or the full suite.

As the app gains features, developers run `swift test --filter FASTQOperation` to catch regressions in any operation's preview generation, payload correctness, or materialization.

---

## 6. Bug Investigation Protocol

For each test that fails:
1. Capture the failure message and root cause
2. Write a minimal reproducer test if the existing test isn't specific enough
3. Fix the bug in the operation's code path
4. Verify the test passes
5. Run full suite to check regressions
6. Commit fix separately from test

---

## 7. Out of Scope

- Full-output operations (deduplicate, humanReadScrub, errorCorrection) — Sub-project 3
- Paired-end operations (merge, repair, interleave/deinterleave) — Sub-project 3
- Special operations (demux, orient, error-correct) — Sub-project 3
- GUI/viewport changes
- Performance benchmarking
