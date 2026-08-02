# Partial MHC Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class `partial-extension` MHC candidate category for strong zero-SNP cDNA extension evidence whose genomic match is not exact and end-to-end.

**Architecture:** Extend the typed candidate classification and make the reciprocal classifier distinguish exact end-to-end genomic matches from partial zero-SNP genomic matches before applying the existing known-allele precedence. Treat partial extensions as extension-like throughout artifacts, workbook projection, and UI, while retaining a distinct raw value, label, and provisional-name suffix. Record the new precedence and outcome counts in provenance.

**Tech Stack:** Swift 6, XCTest, typed Lungfish JSON bundles, GenBank/EMBL/FASTA writers, workbook projection, AppKit genotype viewport.

## Global Constraints

- A partial extension requires positive qualifying cDNA extension evidence; partial genomic coverage alone is insufficient.
- Exact known genomic matches require complete candidate and reference coverage with zero SNPs, insertions, deletions, skipped bases, soft clips, and hard clips.
- Normal extensions remain `<allele>_ext`; partial extensions use `<allele>_partial_ext`.
- Existing bundles containing only `novel` and `extension` must remain readable.
- All scientific outputs must retain complete Lungfish provenance, including the new rules and outcome counts.
- Validation output must be temporary and moved to Trash after inspection.

---

### Task 1: Typed classification and reciprocal decision boundary

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`

**Interfaces:**
- Consumes: `FullLengthONTMHCCandidateAlignment`, `FullLengthONTMHCCDNAStructuralInterpretation`, and `FullLengthONTMHCSAMMetrics`.
- Produces: `ONTMHCCandidateClassification.partialExtension`, `isExtensionLike`, `_partial_ext` candidate records, and an exact genomic-match predicate.

- [ ] **Step 1: Write failing classifier tests**

Add tests that construct both a qualifying cDNA extension alignment and genomic evidence:

```swift
func testIncompleteZeroSNPGenomicMatchWithCDNAExtensionIsPartialExtension() throws {
    let cluster = makeCluster(sequenceLength: 1_200, alignments: [
        alignment(reference: cdnaReference, cigar: "500=50I500="),
        alignment(reference: genomicReference, cigar: "1100=100S"),
    ])
    guard case .candidate(let candidate) = try classifier.classify(cluster) else {
        return XCTFail("Expected partial extension")
    }
    XCTAssertEqual(candidate.classification, .partialExtension)
    XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_partial_ext")
}
```

Add a companion exact genomic alignment test that remains `.known`, a cDNA-only extension test that remains `.extension`, and an ineligible cDNA test that retains current behavior.

- [ ] **Step 2: Run the focused tests and verify the new case fails**

Run:

```bash
swift test --filter FullLengthONTMHCCandidateClassifierTests
```

Expected: the new partial-extension test fails because the enum/case does not yet exist or the result is currently `.known`.

- [ ] **Step 3: Add the typed category and exact-match predicate**

Add:

```swift
case partialExtension = "partial-extension"

public var isExtensionLike: Bool {
    self == .extension || self == .partialExtension
}
```

Implement a classifier helper that accepts an `AnalyzedAlignment` and cluster length and returns true only when the genomic record starts at reference base 1, spans the complete genomic reference and candidate, has zero SNPs, and has no insertion, deletion, skipped-reference, soft-clipped, or hard-clipped bases.

- [ ] **Step 4: Reorder classification without weakening cDNA evidence**

Collect qualifying cDNA extension interpretations before returning a genomic known call. If an exact genomic zero-SNP hit exists, return known. If qualifying cDNA extension evidence and only non-exact zero-SNP genomic hits exist, build `.partialExtension`; if no zero-SNP genomic hit exists, build `.extension`. If no qualifying cDNA extension exists, preserve the existing broad zero-SNP genomic behavior.

- [ ] **Step 5: Run classifier and structural-classifier suites**

```bash
swift test --filter FullLengthONTMHCCandidateClassifierTests
swift test --filter FullLengthONTMHCCDNAStructuralClassifierTests
```

Expected: all tests pass.

### Task 2: Artifact schemas, comments, and provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift` only if extension-like merge validation requires it.
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCEMBLWriterTests.swift`

**Interfaces:**
- Consumes: candidate records from Task 1.
- Produces: candidate JSON schema 5, extension-like GenBank/EMBL comments, and explicit provenance rules/counts.

- [ ] **Step 1: Add failing artifact tests**

Require a partial-extension candidate to round-trip with raw value `partial-extension`, retain all `extension_of` interpretations, publish through candidate FASTA/GenBank/EMBL, and contain comments describing both zero-SNP cDNA extension evidence and incomplete genomic evidence. Update schema assertions from 4 to 5.

- [ ] **Step 2: Run artifact tests and verify failures**

```bash
swift test --filter FullLengthONTMHCCandidateArtifactWriterTests
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests
```

Expected: failures for schema 5, extension-like comments, and the new classification.

- [ ] **Step 3: Generalize extension-only artifact behavior**

Replace extension-only checks with `classification.isExtensionLike`. Keep normal extension wording intact and add a partial-extension comment such as:

```text
Lungfish partial extension: zero-SNP cDNA structural-extension evidence is present, but no exact end-to-end genomic match establishes the complete observed sequence.
```

Include selected genomic alignment start/CIGAR and its insertion, deletion, skipped, soft-clipped, hard-clipped, candidate-span, and reference-span metrics. Preserve existing missing-feature and no-imputation comments.

- [ ] **Step 4: Bump candidate schema and record provenance**

Publish candidate documents as schema 5 and record:

```text
exactGenomicKnownRule=zero-SNP+start-at-reference-base-1+complete-candidate-and-reference-span+zero-I/D/N/S/H
partialExtensionRule=qualifying-cDNA-extension+zero-SNP-genomic-hit+no-exact-end-to-end-genomic-hit
partialExtensionPrecedence=exact-genomic-known;partial-extension;ordinary-extension;legacy-zero-SNP-known
```

Add known, extension, partial-extension, novel, and un-nameable cluster counts to the classification provenance step.

- [ ] **Step 5: Run artifact, EMBL, and provenance suites**

```bash
swift test --filter FullLengthONTMHCCandidateArtifactWriterTests
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests
swift test --filter FullLengthONTMHCEMBLWriterTests
swift test --filter FullLengthONTMHCProvenanceStepTests
```

Expected: all tests pass.

### Task 3: Workbook and viewport presentation

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateAlleleDetailView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Interfaces:**
- Consumes: `partial-extension` records and `_partial_ext` labels.
- Produces: extension-family tinting, “Partial extension” detail/accessibility labels, and workbook validation/projection.

- [ ] **Step 1: Add failing presentation tests**

Add a partial-extension fixture and assert that it uses extension-family tinting, displays “Partial extension,” exports its `_partial_ext` label, and passes current-workbook label validation. Confirm ordinary extension and novel behavior is unchanged.

- [ ] **Step 2: Run focused tests and verify failures**

```bash
swift test --filter FullLengthONTMHCWorkbookProjectionTests
swift test --filter GenotypeWorkbookRevisionServiceTests
swift test --filter GenotypeResultViewportTests
```

Expected: exhaustive-switch compilation failures or missing partial-extension expectations.

- [ ] **Step 3: Implement extension-family presentation**

Map `.partialExtension` to the same tint categories as `.extension`, but return “Partial extension” in detail and accessibility text. Accept only `_partial_ext` as its authoritative workbook label; `_ext` and `_Nnt_nov` are invalid for this classification.

- [ ] **Step 4: Run workbook and UI suites**

Run the three focused commands from Step 2. Expected: all tests pass.

### Task 4: End-to-end DRB validation and completion

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift` if pipeline provenance expectations require schema/rule updates.
- Output only: temporary DRB validation bundle outside the repository.

**Interfaces:**
- Consumes: the built `lungfish-cli`, four reported `.lungfishfastq` bundles, and the versioned Mamu-DRB reference bundle.
- Produces: verified scientific results and a signed debug application.

- [ ] **Step 1: Run broad automated verification**

```bash
swift test --filter FullLengthONTMHCGenotypingPipelineTests
swift test --filter FastqFullLengthONTMHCGenotypingCommandTests
git diff --check
```

Expected: zero failures and no whitespace errors.

- [ ] **Step 2: Run all four DRB samples in one temporary workflow**

Use `.build/debug/lungfish-cli fastq full-length-ont-mhc-genotype` with CN29, CN54, CY44, and DI20; reference `IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2.lungfishref`; and the reported settings (`threads=14`, length 3000–11000, Savont QV 90/minimum cluster 3, minimum unmatched reads 5, cDNA threshold 2000).

- [ ] **Step 3: Inspect biological and provenance outputs**

List all known, extension, partial-extension, novel, and un-nameable outcomes. Confirm partial extensions use `_partial_ext`, have qualifying zero-SNP cDNA evidence, lack an exact end-to-end genomic match, include coverage comments in GenBank/EMBL, appear in workbook projection input, and carry complete provenance with the new rules/counts.

- [ ] **Step 4: Move validation output to Trash**

Move the exact temporary bundle and lock sidecars to uniquely named entries in `/Users/dho/.Trash`; do not delete project data.

- [ ] **Step 5: Build and verify the debug application**

```bash
scripts/build-app.sh --configuration debug
codesign --verify --deep --strict build/Debug/Lungfish.app
build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli --version
```

Expected: signed `Lungfish Debug`, bundle identifier `com.lungfish.browser.debug`, with the updated CLI embedded.

- [ ] **Step 6: Review and commit**

Review the final diff against the approved design, run focused verification again after any correction, and commit the implementation on `codex/sidebar-row-filter-classii` without merging or pushing.

