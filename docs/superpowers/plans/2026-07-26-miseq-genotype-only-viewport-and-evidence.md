# miSeq Genotype-Only Viewport and Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give genotype-only miSeq amplicon MHC results the shared native review experience, durable genotyping BAM/BAI evidence, and provenance-backed “Provisional exon 2” `_nov` sequence presentation without changing haplotyped result behavior.

**Architecture:** Extend the genotype-result manifest with optional generic alignment and provisional-sequence artifact declarations, publish the existing retained BAM/BAI plus a compact observed `_nov` JSON/FASTA catalog, and validate them during the existing off-main bundle load. Feed the resulting keyed sequence catalog into the existing matrix, detail renderer, Inspector artifact list, annotation bridge, and workbook publication paths rather than creating a separate miSeq viewport.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, SwiftUI Inspector sections, CryptoKit SHA-256, LungfishIO bundle validation, LungfishWorkflow provenance envelopes, XCTest.

---

### Task 1: Define generic evidence and provisional-sequence bundle contracts

**Files:**
- Create: `Sources/LungfishIO/Bundles/ONTGenotypeScientificArtifacts.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing manifest round-trip tests**

Add tests that construct a manifest with:

```swift
let alignmentArtifacts = ONTGenotypeAlignmentArtifactManifest(
    genotypingEvidence: .init(
        bam: .init(path: "run.retained.demuxed.bam", sha256: bamSHA, sizeBytes: 3),
        bai: .init(path: "run.retained.demuxed.bam.bai", sha256: baiSHA, sizeBytes: 3)
    ),
    reciprocalEvidence: nil
)
let provisionalArtifacts = ONTGenotypeProvisionalExon2ArtifactManifest(
    schemaVersion: 1,
    catalogJSON: .init(
        path: "artifacts/sequences/observed-provisional-exon2.json",
        sha256: jsonSHA,
        sizeBytes: Int64(jsonData.count)
    ),
    sequencesFASTA: .init(
        path: "artifacts/sequences/observed-provisional-exon2.fasta",
        sha256: fastaSHA,
        sizeBytes: Int64(fastaData.count)
    )
)
```

Assert JSON round-trip, absent reciprocal evidence, and backward decoding of a
manifest without either new field.

- [ ] **Step 2: Run the tests and verify the missing-type failure**

Run:

```bash
swift test --filter 'ONTGenotypeResultBundleTests/testRoundTripsGenericAlignmentArtifacts|ONTGenotypeResultBundleTests/testRoundTripsProvisionalExon2Artifacts|ONTGenotypeResultBundleTests/testDecodesLegacyManifestWithoutScientificArtifacts'
```

Expected: compilation fails because the new artifact contracts and manifest
properties do not exist.

- [ ] **Step 3: Add focused artifact data types and optional manifest fields**

Define:

```swift
public struct ONTGenotypeAlignmentArtifactManifest: Codable, Equatable, Sendable {
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let reciprocalEvidence: ONTMHCBAMArtifactPair?
}

public struct ONTGenotypeProvisionalExon2ArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogJSON: ONTMHCArtifactReference
    public let sequencesFASTA: ONTMHCArtifactReference
}

public struct ONTGenotypeProvisionalExon2Document: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    public let schemaVersion: Int
    public let records: [ONTGenotypeProvisionalExon2Record]
}

public struct ONTGenotypeProvisionalExon2Record: Codable, Equatable, Sendable {
    public let genotype: String
    public let locus: String
    public let fastaRecordID: String
    public let sequenceLength: Int
    public let sequenceSHA256: String
    public let sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]
}
```

Add optional `alignmentArtifacts` and `provisionalExon2Artifacts` properties to
both manifest initializers without changing existing defaults or legacy JSON.

- [ ] **Step 4: Run the focused round-trip tests**

Run the Step 2 command.

Expected: all three tests pass.

- [ ] **Step 5: Commit the contract**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeScientificArtifacts.swift Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: define genotype scientific artifact contracts"
```

### Task 2: Validate and load generic scientific artifacts

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeScientificArtifacts.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing loader tests**

Create a fixture with checksummed BAM/BAI, catalog JSON, and FASTA. Assert:

```swift
XCTAssertEqual(result.alignmentArtifactURLs.genotypingBAM, bamURL)
XCTAssertEqual(result.alignmentArtifactURLs.genotypingBAI, baiURL)
XCTAssertNil(result.alignmentArtifactURLs.reciprocalBAM)
XCTAssertEqual(
    result.provisionalExon2SequencesByGenotype["E_02_nov_17"]?.sequence,
    "ACGT"
)
```

Add one focused failure test for each invariant: traversal, missing file,
checksum mismatch, duplicate genotype, JSON/FASTA sequence mismatch,
non-`_nov` record, and catalog genotype absent from `result.calls`.

- [ ] **Step 2: Run the tests and verify loader failures**

Run:

```bash
swift test --filter 'ONTGenotypeResultBundleTests/testLoadsValidatedGenericGenotypingEvidence|ONTGenotypeResultBundleTests/testLoadsValidatedProvisionalExon2Catalog|ONTGenotypeResultBundleTests/testRejectsInvalidProvisionalExon2'
```

Expected: tests fail because the result does not expose generic alignment URLs
or provisional records.

- [ ] **Step 3: Add a validated loaded model**

Define:

```swift
public struct ONTGenotypeProvisionalExon2Sequence: Codable, Equatable, Sendable {
    public let genotype: String
    public let locus: String
    public let sequence: String
    public let sequenceSHA256: String
    public let sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]

    public var designation: String { "Provisional exon 2" }
}
```

Add `alignmentArtifactURLs` and
`provisionalExon2SequencesByGenotype` to `ONTGenotypeResultBundleData`. Preserve
the existing `mhcAlignmentArtifactURLs` encoded property as a compatibility
alias backed by the same value.

- [ ] **Step 4: Implement one-pass artifact validation**

Reuse the bundle's no-symlink relative-path validation and SHA-256 streaming.
Resolve top-level alignment artifacts for every genotype result. Continue to
fall back to the nested full-length candidate declaration when the generic
declaration is absent.

Parse catalog JSON and FASTA once, then require:

```swift
record.genotype.localizedCaseInsensitiveContains("_nov")
record.sequenceLength == sequence.count
record.sequenceSHA256 == sha256(sequence)
Set(document.records.map(\.genotype)).isSubset(of: Set(calls.map(\.genotype)))
Set(document.records.map(\.fastaRecordID)) == Set(fastaRecords.keys)
```

Return dictionaries keyed by the exact run-recorded genotype identifier.

- [ ] **Step 5: Run bundle tests**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
```

Expected: the full bundle suite passes with no failures.

- [ ] **Step 6: Commit loading and validation**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeScientificArtifacts.swift Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: load genotype evidence and provisional exon 2 catalogs"
```

### Task 3: Publish retained BAM/BAI and observed provisional sequences

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/AmpliconGenotypeScientificArtifactPublisher.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing publisher unit tests**

Build a reference FASTA containing `E_02_nov_17` and `Mafa-E*02:01`, plus calls
for both. Assert the publisher emits only the observed `_nov` record, preserves
the exact identifier and sequence, sorts sample support deterministically, and
returns:

```swift
XCTAssertNotNil(publication.alignmentArtifacts.genotypingEvidence)
XCTAssertNil(publication.alignmentArtifacts.reciprocalEvidence)
XCTAssertEqual(publication.provisionalExon2Document?.records.count, 1)
```

Add tests for case-insensitive `_nov`, zero provisional calls, and a provisional
call missing from the exact reference FASTA.

- [ ] **Step 2: Run the publisher tests and verify RED**

Run:

```bash
swift test --filter AmpliconGenotypeScientificArtifactPublisherTests
```

Expected: compilation fails because the publisher does not exist.

- [ ] **Step 3: Implement deterministic publication**

The publisher must:

1. Read the existing genotype CSV into exact `ONTGenotypeCall` values.
2. Select distinct identifiers containing `_nov`, case-insensitively.
3. Stream the run reference FASTA and retain only those exact records.
4. Write sorted JSON and wrapped FASTA atomically beneath
   `artifacts/sequences/`.
5. Construct checksum/size references for JSON, FASTA, retained BAM, and BAI.
6. Throw a typed error when an observed provisional identifier is absent from
   the exact run reference.

Do not perform network access, allele lookup, alias substitution, or database
version inference.

- [ ] **Step 4: Run publisher tests**

Run the Step 2 command.

Expected: all publisher tests pass.

- [ ] **Step 5: Write failing pipeline durability and provenance tests**

Update the existing pipeline test that currently expects every BAM to be
deleted. Assert instead:

```swift
XCTAssertTrue(fileManager.fileExists(atPath: request.retainedBAMURL.path))
XCTAssertTrue(fileManager.fileExists(atPath: request.retainedBAIURL.path))
XCTAssertFalse(fileManager.fileExists(atPath: request.mappingBAMURL.path))
XCTAssertFalse(fileManager.fileExists(atPath: request.mappingBAIURL.path))
XCTAssertTrue(envelope.outputs.contains { $0.path == request.retainedBAMURL.path })
XCTAssertTrue(envelope.outputs.contains { $0.path == request.retainedBAIURL.path })
XCTAssertEqual(manifest.alignmentArtifacts?.reciprocalEvidence, nil)
```

For an `_nov` fixture, assert the JSON/FASTA descriptors and the reference
FASTA/genotype CSV inputs have checksums and sizes in the provenance envelope.

- [ ] **Step 6: Run the pipeline tests and verify the current cleanup failure**

Run:

```bash
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests
```

Expected: durability tests fail because retained evidence is deleted and the
manifest/provenance do not declare the new artifacts.

- [ ] **Step 7: Integrate publication without changing scientific recipes**

Call the publisher after genotype CSV creation and before provenance/manifest
publication. Pass its declarations into `writeProvenance` and
`writeBundleManifest`. Add retained BAM/BAI and optional provisional JSON/FASTA
to canonical outputs and to the appropriate provenance step outputs.

Replace `removeGeneratedAlignmentIntermediates` with cleanup that removes only
mapping BAM/BAI and transient mapping BAMs:

```swift
let regenerable = [
    request.mappingBAMURL,
    request.mappingBAIURL,
] + mapping.transientBAMURLs
```

- [ ] **Step 8: Run workflow and provenance tests**

Run:

```bash
swift test --filter 'AmpliconGenotypeScientificArtifactPublisherTests|ONTBarcodeDemuxGenotypingPipelineTests|ScientificProvenancePolicyTests'
```

Expected: all selected tests pass; environment-dependent openpyxl tests may
remain skipped.

- [ ] **Step 9: Commit workflow publication**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AmpliconGenotypeScientificArtifactPublisher.swift Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Tests/LungfishWorkflowTests
git commit -m "feat: publish miSeq genotype evidence artifacts"
```

### Task 4: Present Provisional exon 2 rows through the shared matrix

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceRecord.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSearchIndexTests.swift`

- [ ] **Step 1: Write failing viewport presentation tests**

Configure a genotype-only `ont-barcode-genotype` result containing a loaded
`E_02_nov_17` record. Assert:

```swift
XCTAssertTrue(controller.testingComparisonMatrixIsProvisionalExon2("E_02_nov_17"))
XCTAssertTrue(controller.testingMatrixTooltip(genotype: "E_02_nov_17").contains("Provisional exon 2"))
XCTAssertTrue(controller.testingReviewLegend.contains("Provisional exon 2"))
XCTAssertTrue(controller.testingAlleleSequenceText.contains(">E_02_nov_17"))
XCTAssertTrue(controller.testingCurrentSelectionDetails.contains {
    $0.label == "Designation" && $0.value == "Provisional exon 2"
})
```

Assert the allele identity cell receives the provisional amber treatment while
its read-count cell preserves support coloring and FP/FN/comment chrome.

- [ ] **Step 2: Write failing mode-boundary tests**

Use the same `_nov` record with a haplotype analysis and assert the existing
haplotyped lens header, summary mode, Inspector availability, and detail
selection behavior are byte-for-byte/equality unchanged from a non-provisional
haplotyped fixture. Also assert a genotype-only legacy bundle without the new
catalog still behaves as before.

- [ ] **Step 3: Run the viewport tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/testGenotypeOnlyMiSeqPresentsProvisionalExon2Sequence|GenotypeResultViewportTests/testProvisionalExon2DoesNotChangeHaplotypedPresentation|GenotypeResultViewportTests/testProvisionalExon2KeepsEvidenceAndReviewChrome'
```

Expected: tests fail because the matrix has no provisional catalog or
designation presentation.

- [ ] **Step 4: Reuse sequence rendering and keyed matrix state**

Add:

```swift
static func provisionalExon2(_ source: ONTGenotypeProvisionalExon2Sequence) -> Self
```

to `GenotypeAlleleSequenceRecord`, producing deterministic minimal GenBank,
FASTA, and EMBL text from the exact stored sequence without assigning an IPD
accession.

On genotype-only configure, build:

```swift
provisionalExon2Genotypes = Set(result.provisionalExon2SequencesByGenotype.keys)
provisionalExon2SequenceRecords = result.provisionalExon2SequencesByGenotype
    .mapValues(GenotypeAlleleSequenceRecord.provisionalExon2)
```

Pass the immutable set to the existing matrix. Apply a subtle amber background
only to allele identity cells, append the designation to tooltip/accessibility
text, and extend the existing review legend. Do not change read cells.

- [ ] **Step 5: Reuse the detail-pane selection pipeline**

When a genotype-only selected row is provisional, mount the existing
`GenotypeAlleleSequenceDetailView` and publish selection details containing
designation, caveat, locus, sequence length, observed samples, read support,
and applicable comments. Supported-cell selection retains the exact evidence
metrics and adds the same designation context.

- [ ] **Step 6: Include the designation in shared search**

Index “Provisional exon 2” as visible row metadata only for catalog-backed
records. Preserve the original `_nov` identifier as the stable row identity and
search text.

- [ ] **Step 7: Run viewport and search tests**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests|GenotypeSearchIndexTests'
```

Expected: both suites pass.

- [ ] **Step 8: Commit shared viewport presentation**

```bash
git add Sources/LungfishGenotypeUI Tests/LungfishGenotypeUITests
git commit -m "feat: present provisional exon 2 genotype calls"
```

### Task 5: Expose artifacts in the Inspector without changing haplotype controls

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishAppTests/InspectorProvenanceTabTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing Inspector artifact tests**

For genotype-only and haplotyped miSeq results, assert artifact rows include:

```swift
"Genotyping Evidence BAM"
"Genotyping Evidence BAI"
```

For a provisional genotype-only fixture also assert:

```swift
"Observed Provisional Exon 2 JSON"
"Observed Provisional Exon 2 FASTA"
```

Assert neither miSeq fixture includes Reciprocal Evidence, Candidate Alleles,
or Un-nameable Clusters rows.

- [ ] **Step 2: Write failing haplotype-control regression tests**

Capture the View and Document state for equivalent haplotyped results with and
without the new evidence declarations. Assert equality after removing only the
artifact rows, proving no lens, cohort, threshold, annotation, or detail option
changed.

- [ ] **Step 3: Run Inspector tests and verify RED**

Run:

```bash
swift test --filter 'InspectorProvenanceTabTests/testMiSeqScientificArtifacts|InspectorProvenanceTabTests/testMiSeqEvidenceDoesNotChangeHaplotypeControls|GenotypeResultViewportTests/testArtifactsLensListsMiSeqScientificArtifacts'
```

Expected: artifact assertions fail due the existing full-length-only gate.

- [ ] **Step 4: Replace the full-length artifact gate with validated data**

Use `result.alignmentArtifactURLs` for artifact rows regardless of result kind.
List only non-nil URLs. Add provisional JSON/FASTA rows from the validated
artifact URL model. Keep candidate, un-nameable, and reciprocal UI conditional
on their actual validated declarations.

- [ ] **Step 5: Run Inspector and artifact-lens tests**

Run:

```bash
swift test --filter 'InspectorProvenanceTabTests|GenotypeResultViewportTests/testArtifactsLens'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit Inspector integration**

```bash
git add Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishAppTests/InspectorProvenanceTabTests.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: expose miSeq scientific artifacts in inspector"
```

### Task 6: Verify annotation, workbook, routing, and performance integration

**Files:**
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `docs/superpowers/specs/2026-07-26-miseq-genotype-only-viewport-and-evidence-design.md`

- [ ] **Step 1: Add genotype-only miSeq end-to-end routing tests**

Create a real bundle fixture with kind `ont-barcode-genotype`, calls, generic
evidence, and a provisional sequence. Route it through
`MainSplitViewController` and assert the shared matrix and Inspector expose:

- numeric filtering;
- allele/sample substring search;
- row/column show/hide;
- comments;
- false positive and false negative capabilities;
- provisional sequence detail;
- Genotyping Evidence BAM/BAI;
- no Smart Cohorts;
- no Reciprocal Evidence.

- [ ] **Step 2: Add workbook publication regression tests**

Apply cell, row, and column comments plus FP/FN annotations to a short-amplicon
bundle and run the existing workbook revision service fixture. Assert workbook
formatting/comments and annotation audit entries match the established
genotype-only behavior. Assert provisional designation does not create or
modify a user annotation.

- [ ] **Step 3: Add performance tests**

Measure:

1. loading a representative miSeq bundle with BAM/BAI declarations and 100
   provisional records off-main;
2. twenty matrix filter changes;
3. repeated provisional row/cell selections.

Assert no artifact reparse occurs during matrix interaction, sequence records
are indexed once, and existing matrix budgets remain unchanged.

- [ ] **Step 4: Run the integration and performance gate**

Run:

```bash
swift test --filter 'MappingViewportRoutingTests|GenotypeWorkbookRevisionServiceTests|GenotypeResultViewportTests'
```

Expected: all selected tests pass with existing performance thresholds.

- [ ] **Step 5: Run the complete affected test gate**

Run:

```bash
swift test --filter 'ONTGenotypeResultBundleTests|AmpliconGenotypeScientificArtifactPublisherTests|ONTBarcodeDemuxGenotypingPipelineTests|GenotypeSearchIndexTests|GenotypeResultViewportTests|InspectorProvenanceTabTests|MappingViewportRoutingTests|GenotypeWorkbookRevisionServiceTests|ScientificProvenancePolicyTests'
```

Expected: zero failures; openpyxl-dependent tests may skip when the managed
runtime is unavailable.

- [ ] **Step 6: Run release performance verification**

Run the representative genotype matrix performance tests in Release
configuration and compare derived-projection and visible-commit timing against
the existing 50 ms and 100 ms budgets.

- [ ] **Step 7: Review provenance coverage and documentation**

Confirm every durable BAM, BAI, JSON, and FASTA has path, checksum, size,
producer step, reproducible argv, resolved options, runtime identity, exit
status, and wall time. Update the design document only when implementation
names differ, without changing approved semantics.

- [ ] **Step 8: Commit integration coverage**

```bash
git add Tests docs/superpowers/specs/2026-07-26-miseq-genotype-only-viewport-and-evidence-design.md
git commit -m "test: cover miSeq genotype-only review integration"
```

### Task 7: Final review and branch integration

**Files:**
- Review: all files changed from `main`

- [ ] **Step 1: Run formatting and repository hygiene checks**

```bash
git diff --check main...HEAD
git status --short
```

Expected: no whitespace errors and no unexpected generated files.

- [ ] **Step 2: Request independent code review**

Provide the approved design, this plan, base SHA, head SHA, and complete diff to
a reviewer. Resolve every Critical or Important finding with a new failing test
before production changes.

- [ ] **Step 3: Re-run the full affected gate after review fixes**

Repeat Task 6 Steps 5 and 6 from the final committed state.

- [ ] **Step 4: Commit any review fixes**

```bash
git add -A
git commit -m "fix: close miSeq genotype review findings"
```

Skip this commit only when the review produces no changes.

- [ ] **Step 5: Integrate as explicitly authorized**

Because the user requested implementation without additional checkpoints,
merge the verified feature branch into `main`, rerun the affected gate on the
merged commit, and push `main`. Preserve the worktree until the pushed commit
is verified to match `origin/main`.

