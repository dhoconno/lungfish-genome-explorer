# Sub-project 3: Full Materialization + Special Operations Audit

**Date:** 2026-04-06
**Branch:** `fastq-operations-preview`
**Scope:** Integration tests and bug fixes for 9 full-output and special FASTQ operations
**Prerequisite:** Sub-project 1 (test framework, CLI), Sub-project 2 (subset + trim tests)

---

## 1. Goal

Complete the FASTQ operations audit by testing all remaining operations: 4 full single-output, 3 full mixed/paired-output, orient, and demultiplex (both symmetric and asymmetric paths). Special emphasis on demux asymmetric barcode handling — the custom ExactBarcodeDemux engine must be thoroughly tested at the pipeline integration level to prevent regressions.

---

## 2. Operations In Scope

### Category A — Full Single-Output (4)

Produce one FASTQ file stored directly in the bundle (`.full` payload). No virtual pointers, no materialization needed — the output IS the FASTQ.

| Operation | Enum Case | Tool | Key Assertion |
|-----------|-----------|------|---------------|
| Error Correction | `errorCorrection(kmerSize: Int)` | tadpole | Output FASTQ exists, reads present |
| Deduplicate | `deduplicate(preset:substitutions:optical:opticalDistance:)` | clumpify | Output has fewer reads than input |
| Remove Human Reads | `humanReadScrub(databaseID:removeReads:)` | scrub.sh | Output FASTQ exists (synthetic reads pass) |
| Interleave | `interleaveReformat(direction: .interleave)` | reformat.sh | Output has 2x input reads (R1+R2 merged) |

### Category B — Full Mixed/Paired Output (3)

Produce multiple FASTQ files classified by read type (`.fullPaired` or `.fullMixed` payload).

| Operation | Enum Case | Tool | Payload | Key Assertion |
|-----------|-----------|------|---------|---------------|
| Paired-End Merge | `pairedEndMerge(strictness:minOverlap:)` | bbmerge | `.fullMixed` | Merged + unmerged files exist |
| Paired-End Repair | `pairedEndRepair` | repair.sh | `.fullMixed` | Repaired R1/R2 files exist |
| Deinterleave | `interleaveReformat(direction: .deinterleave)` | reformat.sh | `.fullPaired` | R1.fastq + R2.fastq exist, equal read counts |

### Category C — Special Operations (2)

#### Orient
- Enum: `orient(referenceURL:wordLength:dbMask:saveUnoriented:)`
- Tool: vsearch
- Payload: `.orientMap(orientMapFilename:previewFilename:)`
- Assertions: orient-map.tsv exists with +/- entries, preview.fastq exists with oriented reads

#### Demultiplex
- Enum: `demultiplex(kitID:customCSVPath:location:symmetryMode:...)`
- Two code paths:
  - **Symmetric/singleEnd** → cutadapt → per-barcode virtual bundles (`.demuxedVirtual` payload)
  - **Asymmetric + sampleAssignments** → ExactBarcodeDemux (Swift-native) → per-barcode virtual bundles
- Assertions: per-barcode bundles created with read-ids.txt + preview.fastq, correct read assignment, materialization produces correct reads

---

## 3. Test Strategy

### 3.1 Test Locations

| File | Scope |
|------|-------|
| `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` | Category A (full ops) — needs `FASTQDerivativeService` |
| `Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift` | Demux pipeline integration (both code paths) |
| `Tests/LungfishWorkflowTests/OrientOperationTests.swift` | Orient pipeline integration |

### 3.2 Regression Suite Convention

All tests follow the `test<OperationName>RoundTrip` naming pattern established in SP2. The full regression suite remains runnable with:
```bash
swift test --filter "FASTQOperation"         # subset + trim + full ops
swift test --filter "DemultiplexPipeline"     # demux integration
swift test --filter "OrientOperation"         # orient integration
```

### 3.3 Paired-End Test Data

Category B operations require interleaved paired-end input. Tests use `FASTQOperationTestHelper` to write synthetic interleaved FASTQ where R1 and R2 reads alternate (standard interleaved format).

---

## 4. Demux Test Specifications

### 4.1 Asymmetric Exact-Match Path

**Test: `testAsymmetricDemuxAssignsReadsToCorrectSamples`**
- Create synthetic reads with known barcode pairs in multiple orientations:
  - Reads 1-10: Pattern 1 (fwd...rc(rev)) for Sample A
  - Reads 11-20: Pattern 2 (rev...rc(fwd)) for Sample A (reverse complement)
  - Reads 21-30: Pattern 1 for Sample B (different barcode pair)
  - Reads 31-35: No barcodes (unassigned)
- Run `DemultiplexingPipeline.run()` with asymmetric mode + sample assignments
- Assert: Sample A bundle has 20 reads, Sample B has 10, unassigned has 5

**Test: `testAsymmetricDemuxAllFourOrientations`**
- Create reads with one sample's barcodes in all 4 orientation patterns
- Assert: all reads assigned to the correct sample regardless of orientation

**Test: `testAsymmetricDemuxMinimumInsertEnforced`**
- Create reads where barcodes are too close together (insert < minimumInsert)
- Assert: those reads go to unassigned

**Test: `testAsymmetricDemuxBundlesHavePreviewAndReadIDs`**
- After demux, verify each per-barcode bundle has:
  - `read-ids.txt` with correct read IDs
  - `preview.fastq` with valid reads
  - Derived manifest with `.demuxedVirtual` payload

### 4.2 Asymmetric Materialization

**Test: `testAsymmetricDemuxMaterialization`**
- Create asymmetric demux bundles from known input
- Materialize each per-barcode bundle via `FASTQCLIMaterializer`
- Assert: materialized output contains exactly the reads assigned to that barcode

### 4.3 Symmetric Cutadapt Path

**Test: `testSymmetricDemuxCreatesPerBarcodeBundles`**
- Create synthetic reads with known symmetric barcodes
- Run with symmetric mode
- Assert: per-barcode bundles created, read counts reasonable

---

## 5. Orient Test Specifications

**Test: `testOrientRoundTrip`**
- Create synthetic reads, some forward and some reverse-complement relative to a reference
- Run orient against the reference
- Assert: orient-map.tsv exists with +/- entries, preview.fastq exists

**Test: `testOrientMapCorrectness`**
- Verify orient-map.tsv entries match expected orientation for known reads

---

## 6. Category A + B Test Specifications

### Category A

**`testErrorCorrectionRoundTrip`** — 200 reads, 100bp → errorCorrection(kmerSize: 21) → output FASTQ exists, reads present
**`testDeduplicateRoundTrip`** — 100 reads (50 unique + 50 exact duplicates) → deduplicate → output has ~50 reads
**`testHumanReadScrubRoundTrip`** — 50 synthetic reads → humanReadScrub → output exists (no real human reads)
**`testInterleaveRoundTrip`** — Two separate R1/R2 files → interleave → single output with 2x reads

### Category B

**`testPairedEndMergeRoundTrip`** — Interleaved PE reads → merge → mixed output files exist (merged + unmerged)
**`testPairedEndRepairRoundTrip`** — Desynchronized interleaved reads → repair → repaired output files exist
**`testDeinterleaveRoundTrip`** — Interleaved FASTQ → deinterleave → R1.fastq + R2.fastq exist, equal counts

---

## 7. Demux Materialization CLI Integration

SP1 deferred demux materialization from the CLI refactor. SP3 must verify that `FASTQCLIMaterializer` correctly handles `.demuxedVirtual` payloads. The materializer already has code for this case (it was implemented in the `FASTQCLIMaterializer` class) — SP3 tests verify it works end-to-end.

---

## 8. Out of Scope

- Modifying the ExactBarcodeDemux engine (already well-tested at unit level)
- GUI/viewport changes
- Performance benchmarking
- Barcode kit definitions or CSV parsing (tested elsewhere)
