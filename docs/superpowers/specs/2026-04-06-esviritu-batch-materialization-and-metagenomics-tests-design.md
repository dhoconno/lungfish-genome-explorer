# EsViritu Batch Materialization and Metagenomics Test Coverage Design

**Date:** 2026-04-06  
**Scope:** Root-cause analysis + design for EsViritu batch failure and regression-proof test strategy for EsViritu, Kraken2/Bracken, and TaxTriage.

---

## 1. Problem Statement

Running EsViritu in batch mode against imported `.lungfishfastq` bundles failed for every sample in:

- `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports/esviritu-batch-C672A262`

Observed failure (all sample logs):

- `ERROR - input read file not found at /Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports/<sample>.lungfishfastq. exiting.`

The referenced path is a **bundle directory**, not a FASTQ file. For example, this exists:

- `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports/SRR35517702.lungfishfastq/SRR35517702.fastq.gz`

but this does not:

- `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports/SRR35517702.fastq.gz`

---

## 2. Root Cause (Confirmed)

### 2.1 Batch EsViritu skips input materialization

In [`AppDelegate.swift`](/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift), single-sample EsViritu resolves/materializes bundle inputs before pipeline execution (`runEsViritu(config:)`), but `runEsVirituBatch(configs:)` does not.

### 2.2 Wizard intentionally passes bundle URLs

`gatherClassificationBundleURLs()` passes `.lungfishfastq` URLs into metagenomics wizards by design. That is valid only if run paths consistently resolve bundle URLs to concrete FASTQ files before tool invocation.

### 2.3 Validation currently allows directory inputs

`EsVirituConfig.validate()` checks `fileExists` but does not reject directories. So invalid directory paths pass validation and fail only in external tool execution.

### 2.4 Same regression risk exists in Kraken2/Bracken batch path

Single-sample classification resolves inputs first; batch classification path currently executes configs directly. This is the same structural gap as EsViritu batch.

### 2.5 TaxTriage path currently resolves inputs

TaxTriage run path already resolves/materializes per-sample input before pipeline run, but lacks targeted regression coverage for this guarantee.

---

## 3. Design Goals

1. Fix EsViritu batch parity with single-run input resolution.
2. Fix same parity gap for Kraken2/Bracken batch execution.
3. Add explicit, actionable validation errors when directories are passed as input FASTQs.
4. Add deterministic tests that verify expected outputs are produced in expected locations from FASTQ bundle artifacts.
5. Keep user-facing behavior and output structure stable.

---

## 4. Candidate Approaches

### Approach A: Minimal patch in `AppDelegate` only

- Add `resolveInputFiles(...)` calls inside both batch loops.
- Keep existing pipeline/config APIs unchanged.

Pros: Fastest fix.  
Cons: Duplicated resolution logic remains spread across callsites; weaker long-term testability.

### Approach B: Shared metagenomics input-resolution helper (recommended)

- Extract reusable app-layer helper for per-config input resolution/materialization.
- Use helper in single + batch paths for EsViritu, Classification, and TaxTriage.
- Add stricter config validation errors for directory inputs.

Pros: Consistent behavior, less duplication, better test seams, lower recurrence risk.  
Cons: Slightly larger refactor than A.

### Approach C: Move bundle resolution into workflow pipelines

- Pipelines accept bundle URLs and self-resolve before validation.

Pros: Strong encapsulation.  
Cons: Larger behavioral shift, higher migration risk, more cross-module changes.

**Recommendation:** Approach B.

---

## 5. Proposed Design

### 5.1 Runtime behavior changes

1. Batch EsViritu and batch Classification must resolve/materialize bundle inputs exactly like their single-sample counterparts.
2. Any run path invoking metagenomics tools must pass resolved FASTQ file paths (not bundle directories).
3. Batch manifests should continue recording original user-selected inputs (bundle paths), not transient materialized temp paths.

### 5.2 Validation hardening

Add explicit validation failures for "input path is a directory" in:

- `EsVirituConfig`
- `ClassificationConfig`
- `TaxTriageConfig`

This makes failures immediate and user-actionable if a path bypasses app-layer resolution.

### 5.3 Test strategy

#### Layer 1: App-layer regression tests (always-run)

- Verify batch config resolution is applied before pipeline execution for:
  - EsViritu batch
  - Kraken2/Bracken batch
- Verify original input paths are preserved in batch manifest metadata.
- Verify directory input causes explicit config validation error when unresolved.

#### Layer 2: Workflow functional tests with FASTQ artifacts (always-run)

Use small fixture `.lungfishfastq` bundles and deterministic execution doubles to assert:

- EsViritu run emits `*.detected_virus.info.tsv` in expected output directory.
- Classification run emits `classification.kreport`, `classification.kraken`, and optional `classification.bracken` in expected output directory.
- TaxTriage run emits expected report/metrics artifacts in config output directory.

#### Layer 3: Optional real-tool smoke tests (skip-if-missing)

- Keep/extend integration tests that execute real tools when environments/databases exist.
- Not a substitute for deterministic CI coverage.

---

## 6. Acceptance Criteria

1. Re-running EsViritu batch from `.lungfishfastq` imports no longer fails with "input read file not found ... .lungfishfastq".
2. Batch EsViritu and batch Classification call input resolution before pipeline invocation.
3. Config validation rejects directory inputs with explicit errors.
4. New deterministic tests pass and verify outputs are created at expected locations from FASTQ bundle artifacts.
5. Existing metagenomics flows remain backward compatible.

---

## 7. Out of Scope

- Changing result file schemas.
- Redesigning wizard UX.
- Full pipeline architecture rewrite.

