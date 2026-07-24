# Canonical MHC Candidate Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deduplicate full-length ONT MHC `_nov` and `_ext` calls by their exact UTR-trimmed genomic sequence while retaining complete raw consensuses only inside the LGE result bundle.

**Architecture:** Keep reciprocal mapping and classification keyed by complete raw-consensus stable IDs. Make the GenBank liftover builder return a reusable trim/readiness result, then aggregate compatible classified records by the exact trimmed sequence and interpretation fields. Schema-v4 documents bind canonical records to raw observations and raw BAM query IDs; every external sequence artifact and Excel sequence cell consumes the canonical trimmed sequence, while internal bundle artifacts retain full raw evidence and its provenance.

**Tech Stack:** Swift 6, Foundation, CryptoKit, XCTest, LungfishIO Codable bundle models, LungfishWorkflow ONT genotyping pipeline, GenBank/FASTA readers and writers, openpyxl workbook projection, minimap2, samtools.

---

## File Structure

- Create `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift`
  - Defines trim/readiness results, canonical merge keys, aggregation, and deterministic representative selection.
- Modify `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
  - Adds schema-v4 raw-source bindings and optional external sequence identity for non-exportable un-nameable records.
- Modify `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
  - Accepts schema 4 and validates canonical records against raw evidence bindings.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
  - Produces one authoritative lifted record plus reference-readiness/trim metadata for candidates and un-nameable inputs.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
  - Keeps raw mapping inputs internally, canonicalizes classified results, merges compatible records, and writes external trimmed artifacts.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
  - Separates internal raw FASTA paths from public canonical FASTA paths and records the new reproducibility contract.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
  - Emits only canonical trimmed nucleotide sequences and CDS-derived translations.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
  - Accepts schema-v4 canonical candidate documents.
- Modify `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
  - Uses schema-v4 canonical observations without a second heuristic merge.
- Modify `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
  - Allows schema 4 when explicitly updating the workbook.
- Modify focused tests under `Tests/LungfishIOTests` and `Tests/LungfishWorkflowTests`.

### Task 1: Add Schema-v4 Raw/Canonical Bindings

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Test: `Tests/LungfishIOTests/ONTMHCCandidateAllelesV2Tests.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] **Step 1: Write failing schema-v4 round-trip and backward-decoding tests**

Add tests that construct a canonical candidate whose canonical ID differs from
its raw BAM query ID:

```swift
let observation = ONTMHCCandidateObservation(
    stableClusterID: "canonical-a",
    sourceSequenceClusterID: "raw-a",
    sampleID: "Sample-A",
    readGroupID: "Sample-A",
    sourceClusterIDs: ["savont-1"],
    sourceClusterReadCounts: ["savont-1": 7],
    aggregatedSampleReadCount: 7,
    genotypingHitSummaries: []
)
let record = ONTMHCCandidateRecord(
    stableClusterID: "canonical-a",
    sourceSequenceClusterIDs: ["raw-a", "raw-b"],
    representativeSourceSequenceClusterID: "raw-b",
    // existing biological fields...
    fastaRecordID: "canonical-a",
    sequenceSHA256: sha256(trimmedSequence),
    selectedEvidence: locator(queryName: "raw-b")
)
```

Assert schema 4 encodes the three new snake-case fields, round trips them,
allows selected reciprocal evidence to use the representative raw ID, and
synthesizes one-to-one raw/canonical bindings when decoding schemas 1–3.

Add an un-nameable schema-v4 test with `fasta_record_id` and
`sequence_sha256` absent to represent a record that cannot safely be exported.
Add manifest-schema-2 coverage for the internal raw FASTA and typed
source-to-canonical map, while retaining manifest-schema-1 decoding.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'ONTMHCCandidateAllelesV2Tests|ONTGenotypeResultBundleTests|GenotypeWorkbookRevisionServiceTests'
```

Expected: FAIL because the v4 properties/initializers do not exist and schema 4
is rejected.

- [ ] **Step 3: Implement the schema-v4 model**

Add these properties with explicit Codable keys:

```swift
public struct ONTMHCCandidateObservation: Codable, Equatable, Sendable {
    public let stableClusterID: String                 // canonical/document ID
    public let sourceSequenceClusterID: String         // raw consensus/BAM query ID
    // existing fields...
}

public struct ONTMHCCandidateRecord: Codable, Equatable, Sendable {
    public let sourceSequenceClusterIDs: [String]
    public let representativeSourceSequenceClusterID: String
    // existing fields...
}

public struct ONTMHCUnnameableRecord: Codable, Equatable, Sendable {
    public let fastaRecordID: String?
    public let sequenceSHA256: String?
    // existing fields...
}

public struct ONTMHCCandidateSourceIdentityRecord: Codable, Equatable, Sendable {
    public let rawStableClusterID: String
    public let rawSequenceSHA256: String
    public let rawSequenceLength: Int
    public let canonicalStableClusterID: String?
    public let canonicalSequenceSHA256: String?
    public let trimStart: Int?
    public let trimEnd: Int?
    public let referenceReadiness: String
}
```

For old observations, default `sourceSequenceClusterID` to
`stableClusterID`. For old candidate records, default
`sourceSequenceClusterIDs` and `representativeSourceSequenceClusterID` to the
record stable ID. Preserve source compatibility with convenience initializers
that supply one-to-one defaults.

Update bundle integrity validation:

```swift
guard (1...4).contains(schema) else { ... }

if document.schemaVersion >= 4 {
    guard record.sourceSequenceClusterIDs.contains(
        record.representativeSourceSequenceClusterID
    ),
    record.selectedEvidence.queryName == record.representativeSourceSequenceClusterID,
    record.reciprocalHitSummary.queryName == record.representativeSourceSequenceClusterID
    else { throw compactBindingFailure(...) }

    guard let owner = recordsByStableID[observation.stableClusterID],
          owner.sourceSequenceClusterIDs.contains(
              observation.sourceSequenceClusterID
          ) else { ... }
}
```

For schema-v4 un-nameable FASTA validation, require exactly the subset whose
optional FASTA identity/checksum are both present. Reject half-present pairs.
Allow schema 4 in the explicit workbook-update Python loader. Advance the
candidate artifact manifest to schema 2 with optional typed
`raw_unmatched_fasta` and `source_identity_map` references, and make the loader
accept manifest schemas 1 and 2.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift \
  Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift \
  Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift \
  Tests/LungfishIOTests/ONTMHCCandidateAllelesV2Tests.swift \
  Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift \
  Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "feat: separate canonical MHC IDs from raw evidence"
```

### Task 2: Return One Authoritative Trim and Readiness Result

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`

- [ ] **Step 1: Write failing trim-result tests**

Add tests for:

1. a candidate with terminal soft clips and complete lifted CDS returns a
   `referenceReady` result whose sequence excludes both terminal regions;
2. the reverse-strand equivalent returns the same stored-orientation crop;
3. an annotated un-nameable record with complete outer CDS boundaries returns
   a trimmed exportable result;
4. a partial/no-CDS un-nameable record returns `notReferenceReady` and no
   external sequence; and
5. a pseudogene with complete boundaries remains reference-ready even though
   its translation status is `pseudogene`.

Use the intended API:

```swift
let result = try FullLengthONTMHCCandidateGenBankArtifactBuilder()
    .build(from: input)

XCTAssertEqual(result.referenceReadiness, .referenceReady)
XCTAssertEqual(result.trimRange, 2..<8)
XCTAssertEqual(result.externalSequence, "ATGGCT")
XCTAssertEqual(result.record.sequence.asString(), "ATGGCT")
```

- [ ] **Step 2: Run the builder tests and verify RED**

Run:

```bash
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests
```

Expected: FAIL because `build(from:)` and the typed readiness result do not
exist and un-nameable records are still serialized untrimmed.

- [ ] **Step 3: Implement the shared result**

Create the narrow public-within-module types:

```swift
enum FullLengthONTMHCReferenceReadiness: String, Codable, Sendable {
    case referenceReady = "reference-ready"
    case incomplete = "not-reference-ready-incomplete"
    case unavailable = "not-reference-ready-unavailable"
}

struct FullLengthONTMHCCandidateCanonicalization: Sendable {
    let record: GenBankRecord
    let rawSequence: String
    let externalSequence: String?
    let trimRange: Range<Int>?
    let translationStatus: FullLengthONTMHCTranslationStatus
    let referenceReadiness: FullLengthONTMHCReferenceReadiness
}
```

Refactor the builder so `build(from:)` performs projection/liftover exactly
once. `records(from:)` remains as a compatibility wrapper over `build(from:)`.
Set `externalSequence` only when both lifted CDS boundaries are defensible and
translation status is `full-length` or `pseudogene`. Crop/rebase both candidate
and exportable un-nameable records. A not-ready result may retain a raw
in-memory diagnostic record, but that record must not be written to an external
GenBank artifact.

- [ ] **Step 4: Run the builder tests and verify GREEN**

Run the command from Step 2. Update prior tests that expected untrimmed
un-nameable output to assert the new typed not-ready result instead. Expected:
all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift \
  Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift
git commit -m "feat: centralize MHC candidate UTR trimming"
```

### Task 3: Aggregate Compatible Raw Classifications into Canonical Alleles

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`

- [ ] **Step 1: Write failing canonical aggregation tests**

Build two raw groups that differ only in terminal flanks but whose builder
results share an exact trimmed sequence. Assert one candidate result with:

```swift
XCTAssertEqual(document.candidates.count, 1)
XCTAssertEqual(document.candidates[0].independentSampleCount, 2)
XCTAssertEqual(document.candidates[0].supportClass, .shared)
XCTAssertEqual(
    Set(document.candidates[0].sourceSequenceClusterIDs),
    Set([rawID1, rawID2])
)
XCTAssertEqual(
    document.candidates[0].stableClusterID,
    FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: trimmed)
)
XCTAssertEqual(
    document.candidates[0].selectedEvidence.queryName,
    expectedHighestReadRawID
)
```

Also add distinct tests proving no merge for:

- a one-base difference inside the trimmed sequence;
- equal display names with different canonical sequences.

Add conflict tests asserting publication is blocked when the same exact trimmed
sequence has incompatible `_nov`/`_ext`, locus, provisional name, closest
reference allele/raw ID, closest-reference class, `extensionOf`, or
`provisionalNamingAmbiguous` interpretations.

Verify the representative is highest raw total reads, then lexical raw stable ID.

- [ ] **Step 2: Run writer tests and verify RED**

Run:

```bash
swift test --filter FullLengthONTMHCCandidateArtifactWriterTests
```

Expected: FAIL because grouping and stable IDs still use complete consensuses.

- [ ] **Step 3: Implement post-classification canonical aggregation**

In the canonicalizer define a merge key that contains the exact trimmed
sequence and every required interpretation field:

```swift
struct CandidateMergeKey: Hashable {
    let sequence: String
    let classification: ONTMHCCandidateClassification
    let locus: String
    let provisionalName: String
    let closestReferenceName: String
    let closestReferenceRawID: String
    let closestReferenceClass: MHCReferenceMoleculeClass
    let extensionOf: [String]
    let provisionalNamingAmbiguous: Bool
}
```

For each raw classification:

1. build its typed liftover/readiness result from the complete raw sequence;
2. block publication if a named candidate is not reference-ready;
3. hash the external trimmed sequence for canonical ID/checksum;
4. group by `CandidateMergeKey`;
5. aggregate observations after setting each observation's canonical
   `stableClusterID` and raw `sourceSequenceClusterID`;
6. sum occurrence/read counts, recompute independent samples/support class,
   union compatible cDNA interpretations, and choose the representative;
7. retain the representative reciprocal summary/evidence with its raw query ID;
8. create one canonical record and one canonical GenBank input.

Do not rerun minimap2 and do not trim before reciprocal classification.

- [ ] **Step 4: Split internal raw and external canonical FASTA products**

Within the writer stage:

- map minimap2 using `artifacts/internal/raw-unmatched-consensuses.fasta`;
- write `artifacts/internal/mhc-candidate-source-map.json` containing raw ID,
  raw checksum/length, canonical ID when available, trim coordinates,
  readiness, classification, sample IDs, and representative status;
- write `candidate_alleles.fasta` and the public
  `deduplicated_unmatched_clusters.fasta` from canonical candidate sequences;
- write un-nameable FASTA/GenBank only for records with a typed external
  sequence; and
- write schema-v4 candidate/un-nameable JSON using the canonical bindings.

Advance the candidate artifact manifest to schema 2 and include checksum-bound
references for the internal raw FASTA and source map. Keep these references
loadable and provenance-visible but out of the prominent submission-artifact UI.

Update transformation provenance for both raw and canonical artifacts, including
paths, checksums, sizes, identity rules, merge fields, and representative rule.

- [ ] **Step 5: Run writer tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass and
`git diff --check` is clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateCanonicalizer.swift \
  Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift
git commit -m "feat: merge MHC candidates by trimmed genomic identity"
```

### Task 4: Enforce the External Sequence Boundary in Excel and Bundle Loading

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeCandidateAlleleDetailViewTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing projection and viewport-data tests**

Add tests asserting:

- candidate `nucleotide_sequence` equals the UTR-trimmed FASTA/GenBank
  sequence and the former separate full-consensus column is absent;
- translation comes only from the canonical record's lifted CDS;
- a non-exportable un-nameable row has blank nucleotide and translation cells
  plus its reason/stable ID/internal-artifact reference;
- one canonical candidate with two observations produces one normalized row and
  two populated sample-read cells; and
- bundle loading/detail data resolves canonical FASTA by canonical stable ID
  while selected BAM evidence retains the raw query ID.
- every schema gate accepts version 4 and the viewport renders one already
  canonical row without applying a second display-name merge.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter 'FullLengthONTMHCWorkbookProjectionTests|ONTGenotypeResultBundleTests|GenotypeCandidateAlleleDetailViewTests|GenotypeResultViewportTests'
```

Expected: FAIL because workbook types require nonoptional un-nameable sequence
identity and still expose both full and trimmed candidate sequence columns.

- [ ] **Step 3: Implement canonical-only workbook projection**

Change normalized unmatched fields to represent the export contract directly:

```swift
let nucleotideSequence: String?       // canonical trimmed sequence only
let putativeAminoAcidTranslation: String?
let translationStatus: FullLengthONTMHCTranslationStatus
let internalEvidenceReference: String?
```

Remove the semantic distinction that allowed a full candidate FASTA sequence
beside a cropped GenBank sequence. Require candidate FASTA and GenBank sequences
to be exactly equal and checksum-identical. Join un-nameable artifacts by their
optional `fastaRecordID`; emit blank cells when no external sequence exists.
Keep one row per stable candidate and aggregate reads from all canonical-bound
observations.

Update the detail/viewport data path only as required to accept raw selected
evidence query IDs; do not add new UI behavior.

Add validated user-facing Candidate/Un-nameable FASTA URLs beside the existing
GenBank review artifacts. Do not add the raw internal FASTA or source map to the
prominent Inspector/viewport review-artifact list.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter 'FullLengthONTMHCWorkbookProjectionTests|ONTGenotypeResultBundleTests|GenotypeCandidateAlleleDetailViewTests|GenotypeResultViewportTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift \
  Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift \
  Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift \
  Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeCandidateAlleleDetailViewTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: export only trimmed MHC candidate sequences"
```

### Task 5: Publish Internal Evidence and Record Complete Provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCEvidenceProvenance.swift` if shared descriptor roles need extension
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCProvenanceStepTests.swift`

- [ ] **Step 1: Write failing pipeline/provenance tests**

Add a staged-run test that verifies:

```swift
XCTAssertTrue(exists("artifacts/internal/raw-unmatched-clusters.fasta"))
XCTAssertTrue(exists("artifacts/internal/raw-unmatched-consensuses.fasta"))
XCTAssertTrue(exists("artifacts/internal/mhc-candidate-source-map.json"))
XCTAssertEqual(readFASTA("deduplicated_unmatched_clusters.fasta"), canonicalCandidates)
XCTAssertFalse(publicArtifactsContain(rawTerminalFlank))
```

Assert the candidate artifact manifest/document validates checksums for internal
raw evidence without adding prominent Inspector rows, and the final provenance
contains:

- schema 4;
- raw and canonical identity/hash rules;
- outer-lifted-CDS trimming/readiness rule;
- complete merge-key fields;
- representative selection rule;
- source-to-canonical counts;
- exact final paths/checksums/sizes;
- argv, resolved defaults/options, runtime/tool identity, timestamps, wall time,
  exit status, and useful stderr.

- [ ] **Step 2: Run pipeline/provenance tests and verify RED**

Run:

```bash
swift test --filter 'FullLengthONTMHCGenotypingPipelineTests|FullLengthONTMHCProvenanceStepTests'
```

Expected: FAIL because raw unmatched FASTA is still root-level and provenance
describes complete consensus as candidate identity.

- [ ] **Step 3: Move raw workflow products under internal artifacts**

Give the request separate paths:

```swift
var rawUnmatchedClustersFASTAURL: URL {
    outputDirectory.appendingPathComponent("artifacts/internal/raw-unmatched-clusters.fasta")
}
var rawDeduplicatedUnmatchedClustersFASTAURL: URL {
    outputDirectory.appendingPathComponent("artifacts/internal/raw-unmatched-consensuses.fasta")
}
var deduplicatedUnmatchedClustersFASTAURL: URL {
    outputDirectory.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
}
```

Write mapping/classification inputs to the two internal paths. Publish the
external root-level path only after canonicalization. Ensure cleanup does not
remove internal evidence and atomic publication still treats the whole bundle
as one generation.

- [ ] **Step 4: Update provenance and manifest references**

Replace the old `candidateSequenceIdentityRule` with explicit raw/canonical
rules and include every required AGENTS.md field. Point all successful
descriptors to their final bundle paths. Ensure failure provenance names any
staged internal inputs that existed before failure.

- [ ] **Step 5: Run pipeline/provenance tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift \
  Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCEvidenceProvenance.swift \
  Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCProvenanceStepTests.swift
git commit -m "feat: retain raw MHC evidence inside result bundles"
```

### Task 6: Verify the Integrated Workflow and Produce the Exemplar Bundle

**Files:**
- Modify only if integration tests reveal an in-scope defect.
- Test: all focused suites above plus the full relevant module suites.

- [ ] **Step 1: Run all focused tests**

```bash
swift test --filter 'ONTMHCCandidateAllelesV2Tests|ONTGenotypeResultBundleTests|FullLengthONTMHCCandidateGenBankArtifactBuilderTests|FullLengthONTMHCCandidateArtifactWriterTests|FullLengthONTMHCWorkbookProjectionTests|GenotypeCandidateAlleleDetailViewTests|GenotypeWorkbookRevisionServiceTests|FullLengthONTMHCGenotypingPipelineTests|FullLengthONTMHCProvenanceStepTests'
```

Expected: PASS.

- [ ] **Step 2: Run the broader relevant suites**

```bash
swift test --filter 'LungfishIOTests|LungfishWorkflowTests|LungfishGenotypeUITests'
```

Expected: PASS except for any documented pre-existing unrelated failure proven
unchanged from the base commit.

- [ ] **Step 3: Recover the exact exemplar argv**

Read the successful provenance from:

```text
/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-22-structural-ext-debug-v4.lungfishgenotype
```

Use its exact four input bundles, reference bundle, and resolved user-visible
options. Change only:

```text
--output-dir .../2026-07-23-canonical-identity-debug-v1.lungfishgenotype
--output-name 2026-07-23-canonical-identity-debug-v1
```

- [ ] **Step 4: Run the new CLI and validate the biological result**

Run the newly built `lungfish-cli` command. Validate with an independent script:

- four extension display names each occur once, not twice;
- their support class is shared and each has both expected sample IDs;
- the known duplicate novel pairs collapse only when trimmed sequences are
  byte-identical;
- candidates with different trimmed sequences remain distinct;
- every candidate FASTA sequence equals its GenBank ORIGIN and Excel nucleotide
  cell;
- every public sequence is UTR-trimmed;
- raw full consensuses and flanks exist only under `artifacts/internal`;
- BAM and BAI artifacts pass `samtools quickcheck`/`idxstats`; and
- all manifest/provenance checksums and sizes match.

- [ ] **Step 5: Build and relaunch Lungfish Debug**

Build the worktree Debug app using the repository's established debug-build
command. Verify:

```text
CFBundleDisplayName = Lungfish Debug
CFBundleName = Lungfish Debug
CFBundleIdentifier = com.lungfish.browser.debug
```

Quit all other Lungfish instances, launch only the newly built Debug app, and
open the new exemplar bundle.

- [ ] **Step 6: Final review and commit any integration-only fix**

Run `git diff --check`, inspect `git status`, and request a final whole-change
code review. If integration required a fix, commit it with:

```bash
git add <exact in-scope files>
git commit -m "fix: complete canonical MHC candidate publication"
```
