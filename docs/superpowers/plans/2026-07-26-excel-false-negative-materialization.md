# Excel False-Negative Materialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make zero-support false-negative annotations reproducibly materialize as authoritative annotation-only workbook rows with a literal `FN` marker and exact cross-Excel styling.

**Architecture:** Publish one immutable, manifest-attested reviewable-row catalog from the exact run inputs and use it as the shared authority for native and openpyxl workbook paths. Recognized layout adapters synthesize and later safely remove managed annotation-only rows; the sidecar requests a review but never supplies scientific row identity or evidence.

**Tech Stack:** Swift 6, Foundation, Codable, XCTest, Python 3 managed runtime, openpyxl, OOXML, Lungfish canonical provenance.

---

### Task 1: Define and validate the reviewable-row catalog

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeReviewableRowCatalog.swift`
- Create: `Sources/LungfishIO/Bundles/GenotypeReviewableRowResolver.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:210-454`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [x] **Step 1: Write failing round-trip and authority-validation tests**

Add tests that construct a catalog with two samples, one reference row, and one
provisional candidate row. Assert distinct authoritative call ID and display
label, successful round-trip, exact known-reference versus candidate match
rules, and rejection of duplicate semantic identities, duplicate roster
samples, evidence samples outside the roster, missing roster evidence,
unsupported schema, nonzero cohort-zero rows, path traversal, symlink
artifacts, size mismatch, and checksum mismatch.

```swift
let catalog = GenotypeReviewableRowCatalog(
    schemaID: GenotypeReviewableRowCatalog.schemaID,
    schemaVersion: 1,
    samples: ["S1", "S2"],
    rows: [
        .init(
            kind: .reference,
            callID: "reference:MHC-A:Mafa-A1*001:01",
            displayName: "Mafa-A1*001:01",
            locus: "MHC-A",
            stableID: nil,
            section: "reference",
            sortKey: "MHC-A|Mafa-A1*001:01",
            supportBySample: ["S1": 0, "S2": 0]
        )
    ]
)
XCTAssertNoThrow(try catalog.validated())
```

- [x] **Step 2: Run the test and verify RED**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: compile failure because `GenotypeReviewableRowCatalog` and the manifest descriptor do not exist.

- [x] **Step 3: Implement the typed catalog and manifest field**

Define exact semantic identity by `(kind, canonical locus, authoritative
callID, stableID)` and keep display label separate; require stable IDs for
provisional/candidate rows and forbid them for known-reference rows. Implement
`GenotypeReviewableRowResolver` as the only catalog-side semantic resolver used
by native and openpyxl request preparation. Require each roster sample exactly
once with an explicit nonnegative support value. Add an optional
`reviewableRowCatalog` `ONTMHCArtifactReference` to
`ONTGenotypeResultBundleManifest`, preserve it through every initializer, and
load a validated catalog into `ONTGenotypeResultBundleData`.

```swift
public struct GenotypeReviewableRowCatalog: Codable, Equatable, Sendable {
    public static let schemaID = "org.lungfish.genotype.reviewable-row-catalog"
    public let schemaID: String
    public let schemaVersion: Int
    public let samples: [String]
    public let rows: [Row]

    public func validated() throws -> Self {
        guard schemaID == Self.schemaID, schemaVersion == 1 else {
            throw ValidationError.unsupportedSchema
        }
        // Validate unique roster, exact evidence keys, row-kind identity, and
        // unique semantic identities in one bounded pass.
        return self
    }
}
```

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'ONTGenotypeResultBundleTests|GenotypeAnnotationSidecarTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeReviewableRowCatalog.swift Sources/LungfishIO/Bundles/GenotypeReviewableRowResolver.swift Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: add attested genotype review row catalog"
```

### Task 2: Build the catalog from authoritative run outputs

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeReviewableRowCatalogPublisher.swift`
- Create: `Tests/LungfishWorkflowTests/GenotypeReviewableRowCatalogPublisherTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/AmpliconGenotypeScientificArtifactPublisher.swift:31-207`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:830-842`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:1273-1709`
- Test: `Tests/LungfishWorkflowTests/AmpliconGenotypeScientificArtifactPublisherTests.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [x] **Step 1: Write failing publisher tests**

Cover reference rows absent from every sample, supported rows, `_nov`
provisional exon-2 rows, full-length candidate stable IDs, exact roster
reconciliation, duplicate candidate rejection, descriptor publication,
rollback, and complete canonical provenance: tool/version, exact argv, visible
options and resolved defaults, runtime identity, descriptors for reference,
roster, call/evidence projection and candidate artifacts, output
path/SHA-256/size, exit status, wall time, and stderr/error outcome.

- [x] **Step 2: Run the tests and verify RED**

Run: `swift test --filter GenotypeReviewableRowCatalogPublisherTests`

Expected: compile failure because the publisher does not exist.

- [x] **Step 3: Implement one shared publisher**

The builder accepts already validated, checksummed authorities; it does not read a workbook, sidecar, or installed allele database.

```swift
public struct GenotypeReviewableRowCatalogInputs: Sendable {
    public let referenceRecords: [MHCReferenceRecord]
    public let authoritativeSamples: [String]
    public let calls: [ONTGenotypeSharedCall]
    public let candidates: [ONTMHCCandidateAllele]
    public let inputDescriptors: [ProvenanceFileDescriptor]
}

public struct GenotypeReviewableRowCatalogPublication: Sendable {
    public let document: GenotypeReviewableRowCatalog
    public let artifact: ONTMHCArtifactReference
    public let outputURL: URL
    public let provenance: ProvenanceEnvelope
}
```

Compute per-sample evidence from the authoritative calls/candidate observations and reconcile every emitted value. Publish atomically, hash the final file, then include it in the result manifest and canonical provenance for genotype-only miSeq and full-length ONT runs. Do not change reciprocal artifact rules.

- [x] **Step 4: Run pipeline and provenance tests**

Run: `swift test --filter 'GenotypeReviewableRowCatalogPublisherTests|AmpliconGenotypeScientificArtifactPublisherTests|ONTBarcodeDemuxGenotypingPipelineTests|FullLengthONTMHCGenotypingPipelineTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeReviewableRowCatalogPublisher.swift Sources/LungfishWorkflow/ONTGenotyping/AmpliconGenotypeScientificArtifactPublisher.swift Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Tests/LungfishWorkflowTests
git commit -m "feat: publish authoritative workbook review rows"
```

### Task 3: Preserve catalog authority through revisions and fingerprints

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift:264-289`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift:155-218`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift:7-145`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift:68-124`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:4654-4669`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:428-437`
- Test: `Tests/LungfishWorkflowTests/GenotypeCurrentWorkbookInputFingerprintTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift`

- [x] **Step 1: Write failing preservation and fingerprint tests**

Assert that workbook and AI revisions retain the exact catalog descriptor; changing catalog size/hash/schema dirties the workbook; and a false-negative update without an attested catalog fails closed before mutation.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeCurrentWorkbookInputFingerprintTests|GenotypeCurrentWorkbookSyncCoordinatorTests'`

Expected: assertions fail because catalog identity is absent from the fingerprint.

- [x] **Step 3: Thread the validated descriptor through snapshots and staging**

Bump fingerprint schema and add:

```swift
public let reviewableRowCatalogPath: String?
public let reviewableRowCatalogSize: UInt64?
public let reviewableRowCatalogSHA256: String?
public let reviewableRowCatalogSchemaVersion: Int?
```

Stage the verified catalog as a durable workbook-revision input, include it in replay argv and provenance, and reject false-negative processing when it is absent or invalid.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeCurrentWorkbookInputFingerprintTests|GenotypeCurrentWorkbookSyncCoordinatorTests|GenotypeWorkbookRevisionServiceTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeCurrentWorkbookInputFingerprint.swift Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift Tests
git commit -m "feat: attest review catalog in workbook revisions"
```

### Task 4: Add openpyxl layout adapters and synthetic-row lifecycle

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift:796-1146`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [x] **Step 1: Add failing missing-row lifecycle tests**

Add fixtures for unified and supported generic layouts. Assert one
annotation-only row is appended in a labeled, canonically sorted end block; two
FNs share one row; repeat update is idempotent; final clear removes an untouched
synthetic row; user-edited rows remain with a warning; a later real row
supersedes the synthetic row; duplicate aliases and unsupported layouts fail
closed; table/autofilter/formula/merge/freeze structures remain valid.

For unified rows assert field-by-field: explicit annotation-only `call_type`,
authoritative call ID, display name, locus, optional stable ID, occurrence
count/sample count/total cluster reads numeric zero, zero observed samples,
zero supporting reads, analyst-metadata marker, blank sample evidence before
`FN`, and adapter-owned styles. Assert the table/autofilter end ranges expand
exactly to include the block.

- [x] **Step 2: Run the focused new test and verify RED**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests/testAbsentZeroSupportFalseNegativeCreatesManagedAnnotationOnlyRow`

Expected: failure with the existing “No workbook cell matches” validation result.

- [x] **Step 3: Implement explicit adapters and ordered mutation**

Replace heuristic synthesis with adapter detection. The script must:

1. restore prior managed properties and remove safe synthetic rows;
2. append the adapter-owned annotation block without blanket `insert_rows`;
3. rebuild semantic descriptors;
4. validate catalog identity and zero support;
5. write audit/validation and ordinary comments/styles;
6. apply false negatives last.

Managed state stores complete serialized original and expected managed value/font/fill/border plus semantic identity and synthetic-row status. Restore a property only when it still equals the expected managed property.

- [x] **Step 4: Run workbook lifecycle tests**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests`

Expected: all workbook revision tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "feat: materialize managed false negative rows"
```

### Task 5: Apply exact `FN` presentation and provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift:1125-1146`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift:1726-1905`
- Modify: `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift:25-254`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`

- [x] **Step 1: Write failing exact-style and provenance tests**

Inspect the produced OOXML and openpyxl-loaded cells. Assert literal `FN`, `mediumDashed` on all sides, border color `FFC65911`, fill `FFFFF2CC`, bold font color `FF7F6000`, preserved composed comment, blank-versus-zero restoration, and output provenance containing sidecar revision/hash, catalog descriptor, adapter version, synthesized identities/cells, decisions, output descriptor, runtime, argv, exit, wall time, and stderr.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests/testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation`

Expected: failure because the existing style is a thick black border and the cell has no `FN` text.

- [x] **Step 3: Implement style and structured script result**

Use:

```python
fn_side = Side(style="mediumDashed", color="FFC65911")
cell.value = "FN"
cell.border = Border(left=fn_side, right=fn_side, top=fn_side, bottom=fn_side)
cell.fill = PatternFill(fill_type="solid", fgColor="FFFFF2CC")
cell.font = copy(cell.font, bold=True, color="FF7F6000")
```

Return adapter, restoration, synthesis, and target-cell decisions in structured script JSON; parse them into the canonical revision provenance.

- [x] **Step 4: Run service and CLI tests**

Run: `swift test --filter 'GenotypeWorkbookRevisionServiceTests|FastqGenotypingCommandTests|ScientificCLIProvenanceCoverageTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift Tests
git commit -m "fix: render false negatives portably in Excel"
```

### Task 6: Add native export parity

**Files:**
- Modify: `Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift:296-923`
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift:104-354`
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportProvenanceSupport.swift:4-48`
- Modify: `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`
- Test: `Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift`
- Test: `Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift`

- [x] **Step 1: Write failing native-export parity tests**

Assert that a missing authoritative row is appended once, exact OOXML style tokens match openpyxl output, comments compose, catalog checksum failure stops export, formula-like labels remain literal, and provenance contains the same semantic inputs/decisions.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter GenotypeExportSubcommandTests`

Expected: the missing-row and literal `FN` assertions fail.

- [x] **Step 3: Reuse the typed resolver in the native writer**

Accept the validated catalog in `writeViewProjection`, resolve rows through
`GenotypeReviewableRowResolver`, and reuse the same cross-path semantic fixture
set as the openpyxl tests. Append the annotation block before projection
semantics and emit exact border/fill/font OOXML. Replace the export command’s
`try?` bundle load with fail-closed validated loading when false negatives
exist. Native initial workbook/export and openpyxl `current.xlsx` must therefore
share catalog eligibility, exact identity, zero-support, and synthetic-row
semantics.

- [x] **Step 4: Run parity and regression tests**

Run: `swift test --filter 'GenotypeExportSubcommandTests|GenotypeWorkbookRevisionServiceTests|ONTGenotypeResultBundleTests'`

Expected: all selected tests pass.

Verified on 2026-07-27: all 30 `GenotypeExportSubcommandTests`, all 45 tests
selected across genotype export, LabKey export, and viewport Excel export, all
21 `ProvenanceSigningTests`, all 103 `ONTGenotypeResultBundleTests`, and the
consumed-input-snapshot provenance builder test pass. The Task 5
portable-presentation service test also passes. A deterministic concurrent
publication test verifies that the output-directory lock serializes payload,
root-provenance, and sidecar publication and that one failed export cannot
roll back another export's committed provenance. A separate noncooperating
writer regression verifies CAS-aware rollback witnesses preserve atomic
workbook replacement plus same-inode root-provenance, sidecar, and provenance
generation-tree edits. Regular-file witnesses bind no-follow identity, size,
and SHA-256; directory witnesses bind the exact recursive tree. Rollback first
claims each pathname by atomic same-parent exclusive detachment, validates the
detached artifact, and uses exclusive restoration so a writer arriving during
rollback is never overwritten. Mutation callbacks refresh only the exact
affected path or directory branch; unrelated sibling state remains bound to
the transaction-start witness, preventing external edits from being adopted
and avoiding repeated workbook hashing. `ProvenanceWriter` emits mutation-level
operation receipts after each atomically claimed provenance document write,
bundle directory preparation, managed-artifact removal, and transactional
signature/public-key publication (including a provider that publishes both
artifacts and then throws). Genotype export refreshes its witness from those
receipts without re-reading a public pathname after mutation. Signing providers
declare their exact artifact locations; mutation-aware publication requires a
transactional provider and rejects a successful result whose returned paths
differ from the declaration. A rollback regression covers that successful
mismatch path and restores all declared artifacts. Injected failures
after root provenance, a true `.lungfish*` bundle rollup, its focused output
sidecar, the external output sidecar, and stale signature/public-key removal
each restore the prior payload and provenance generation. The broader revision-service
class cannot run as a whole in the managed sandbox because its pre-existing
publication-attestation fixtures write to the user Application Support
directory; Task 6 does not modify that service.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift Sources/LungfishCLI/Commands/GenotypeExportProvenanceSupport.swift Sources/LungfishCLI/Support/CLIProvenanceSupport.swift Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift
git commit -m "feat: match false negative semantics in native export"
```

### Task 7: Verify Excel materialization end to end

**Files:**
- Create: `Tests/LungfishWorkflowTests/GenotypeWorkbookFalseNegativePerformanceTests.swift`
- Modify: `docs/verification/excel-false-negative-materialization.md`

- [ ] **Step 1: Run focused tests**

Run: `swift test --filter 'GenotypeReviewableRowCatalogPublisherTests|GenotypeCurrentWorkbookInputFingerprintTests|GenotypeWorkbookRevisionServiceTests|GenotypeExportSubcommandTests'`

Expected: all selected tests pass.

- [ ] **Step 2: Exercise managed openpyxl re-save**

Generate a workbook fixture, update it, load/save it through the managed openpyxl runtime, unzip both workbooks, and verify `FN`, style tokens, comments, table ranges, and hidden managed state remain valid.

- [ ] **Step 3: Record verification evidence**

Document commands, test counts, fixture identities, catalog and sidecar hashes, and native/openpyxl comparison results in `docs/verification/excel-false-negative-materialization.md`.

- [ ] **Step 4: Run integrity checks and commit**

Run: `git diff --check && swift test --filter 'GenotypeWorkbookRevisionServiceTests|GenotypeExportSubcommandTests'`

Expected: no whitespace errors and all selected tests pass.

```bash
git add docs/verification/excel-false-negative-materialization.md
git commit -m "docs: verify false negative workbook materialization"
```

- [ ] **Step 5: Run performance, full-suite, and release gates**

Use a representative large workbook fixture and assert synthesis is linear in
catalog/workbook rows plus current false-negative annotations, with bounded
memory and no repeated all-cell worksheet scans. Assert workbook-synthesis
signpost/counter evidence is emitted.

Run:
`swift test -c release --filter GenotypeWorkbookFalseNegativePerformanceTests`

Expected: the release performance test passes.

Run: `swift test`

Expected: the full Swift suite passes with no unexpected failures.

Run:
`python3 -m unittest scripts.tests.test_release_smoke scripts.tests.test_sparkle_release_packaging`

Expected: both release-validation modules pass. Record exact commands, test
counts, timings, and outputs without publishing or uploading a release.
