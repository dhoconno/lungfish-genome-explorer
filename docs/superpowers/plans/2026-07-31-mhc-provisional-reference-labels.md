# Provisional MHC Reference Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make full-length ONT MHC genotyping accept the reported reference bundle's controlled provisional allele fields and reject an invalid reference before sample processing.

**Architecture:** Extend the existing MHC allele validator rather than adding a second naming path. Materialize the reference-catalog projection at the beginning of `runStaged`, retain its records and provenance step, and reuse both in the remainder of the pipeline.

**Tech Stack:** Swift 6, XCTest, SQLite-backed `.lungfishref` metadata, existing Lungfish provenance models.

## Global Constraints

- Accept only `ext` plus digits and `new` plus digits as nonnumeric colon-delimited provisional fields.
- Keep the existing `Species-Locus*designation` checks and require a numeric first designation field.
- Do not change plain FASTA reference behavior.
- Preserve complete reproducibility provenance for the reference-catalog import and failed runs.

---

### Task 1: Provisional allele-name validation

**Files:**
- Modify: `Tests/LungfishIOTests/MHCReferenceRecordCatalogTests.swift`
- Modify: `Sources/LungfishIO/Bundles/MHCReferenceRecordCatalog.swift`

**Interfaces:**
- Consumes: `MHCReferenceRecordCatalog.load(from:cdnaThreshold:)`
- Produces: acceptance of `Mamu-E*02:16:ext01`, `Mamu-E*02:new14:new01`, and `Mamu-E*000:new01` through the existing catalog API.

- [ ] **Step 1: Write failing catalog tests**

Add fixtures asserting that controlled provisional annotations and FASTA descriptions load with locus `Mamu-E`. Add a table of malformed values—`Mamu-E*ext01`, `Mamu-E*02:ext`, `Mamu-E*02:other01`, and `Mamu-E*02::new01`—that continues to throw `invalidAlleleAnnotations` when supplied as metadata.

- [ ] **Step 2: Verify the new tests fail for the intended reason**

Run: `swift test --filter MHCReferenceRecordCatalogTests`

Expected: provisional acceptance tests fail with `invalidAlleleAnnotations` or `unresolvedAlleleOrLocus`; existing and malformed-name tests pass.

- [ ] **Step 3: Implement the minimal field validator**

Keep locus validation unchanged. Split the designation on `:` and require:

```swift
guard let firstField = fields.first,
      isNumericAlleleField(firstField) else { return false }
return fields.dropFirst().allSatisfy {
    isNumericAlleleField($0) || isControlledProvisionalField($0)
}
```

`isNumericAlleleField` accepts one or more digits followed only by optional ASCII letters. `isControlledProvisionalField` accepts a case-sensitive `ext` or `new` prefix followed by one or more ASCII digits.

- [ ] **Step 4: Verify catalog tests pass**

Run: `swift test --filter MHCReferenceRecordCatalogTests`

Expected: all catalog tests pass with no failures.

- [ ] **Step 5: Commit the parser change**

Commit `MHCReferenceRecordCatalog.swift` and its tests with message `fix: accept provisional MHC reference labels`.

---

### Task 2: Reference catalog preflight

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`

**Interfaces:**
- Consumes: `materializeMHCReferenceCatalog(sourceURL:fastaURL:cdnaThreshold:outputURL:)`
- Produces: one early `FullLengthONTMHCReferenceCatalogProjection` plus its existing `FullLengthONTMHCProvenanceStep`, reused by downstream genotyping.

- [ ] **Step 1: Write a failing early-validation test**

Build a real `.lungfishref` fixture with a malformed `feature.allele`, run the fake pipeline, capture progress messages in a lock-protected test helper, and assert the run reports the catalog error without emitting `Staging FASTQ` or `Processing` progress. Assert the failed-run provenance exists and records exit status 1.

- [ ] **Step 2: Verify the test fails for the intended reason**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests/testMalformedReferenceCatalogFailsBeforeSampleStaging`

Expected: the captured messages include sample staging because the current pipeline validates the catalog after sample processing.

- [ ] **Step 3: Move catalog materialization before sample staging**

In `runStaged`, declare the final catalog projection path after the staged output directories are created, then call `materializeMHCReferenceCatalog` before `stageSamples`. Remove the later duplicate call and continue using the retained `referenceCatalog.records` and `referenceCatalog.step` values.

- [ ] **Step 4: Verify early failure and provenance tests**

Run:

```sh
swift test --filter FullLengthONTMHCGenotypingPipelineTests/testMalformedReferenceCatalogFailsBeforeSampleStaging
swift test --filter FullLengthONTMHCGenotypingPipelineTests/testReferenceCatalogImportWritesExplicitProvenance
```

Expected: both tests pass; the successful run still contains exactly one catalog-import provenance step with checksummed inputs and output.

- [ ] **Step 5: Commit the preflight change**

Commit the pipeline and tests with message `fix: preflight MHC reference catalogs`.

---

### Task 3: Reference-bundle and regression verification

**Files:**
- No production files added.

**Interfaces:**
- Consumes: the actual reported `.lungfishref` bundle.
- Produces: verification evidence that all 94 reference records load under the patched validator.

- [ ] **Step 1: Run the focused catalog and pipeline suites**

Run:

```sh
swift test --filter MHCReferenceRecordCatalogTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
```

- [ ] **Step 2: Load the reported reference through Lungfish code**

Run a focused XCTest or existing CLI validation path against `/Volumes/iWES_WNPRC/32491/32491.lungfish/Reference Sequences/IPD-MHC_Mamu-E_incl-provisional.lungfishref` and verify it resolves 94 catalog records without editing the bundle.

- [ ] **Step 3: Run the full test suite and inspect the final diff**

Run `swift test`, record any unrelated pre-existing failures separately, and verify `git diff main...HEAD` contains only the approved parser, pipeline ordering, tests, and documentation changes.

