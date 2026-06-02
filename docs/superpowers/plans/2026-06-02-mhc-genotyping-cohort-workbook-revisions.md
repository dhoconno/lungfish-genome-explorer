# MHC Genotyping Cohort and Workbook Revisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix multi-FASTQ MHC genotyping so Illumina sample inputs are mapped independently before merged analysis, and add a managed editable workbook/revision model for `.lungfishgenotype` bundles.

**Architecture:** Keep the existing `fastq genotype` single-run pipeline as the core workflow, add a `fastq genotype-cohort` CLI/app command surface for multi-source Illumina runs, and change Illumina mapping so each prepared sample FASTQ gets its own minimap2 invocation before BAM merge/filter/report. Extend the genotype bundle manifest with original/current workbook paths and put revision-changing workbook actions in a `LungfishWorkflow` service because they write provenance.

**Tech Stack:** Swift Package Manager, XCTest, ArgumentParser, `LungfishIO` bundle models, `LungfishWorkflow` provenance, existing conda-managed minimap2/samtools/pysam/openpyxl workflow.

---

### Task 1: Manifest Supports Original And Current Workbooks

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Modify app fallback helper later: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift`

- [ ] **Step 1: Write the failing IO tests**

Add tests proving:

```swift
func testLoadsCurrentWorkbookWhenManifestHasEditableWorkbookPath() throws
func testCurrentWorkbookURLFallsBackToPrimaryWorkbookForOldBundles() throws
```

The first test creates `generated.xlsx` and `artifacts/workbooks/current.xlsx`, writes a manifest with both `primaryWorkbookPath` and `currentWorkbookPath`, and asserts:

```swift
XCTAssertEqual(try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL), generatedURL.standardizedFileURL)
XCTAssertEqual(try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL), currentURL.standardizedFileURL)
XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: bundleURL).artifacts.workbookURL, currentURL.standardizedFileURL)
XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: bundleURL).artifacts.primaryWorkbookURL, generatedURL.standardizedFileURL)
```

The second test writes the old manifest shape and asserts `currentWorkbookURL(for:)` and `artifacts.workbookURL` both resolve to `primaryWorkbookPath`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
```

Expected: compile/test failure because `currentWorkbookPath`, `workbookRevisions`, `currentWorkbookURL(for:)`, and `artifacts.primaryWorkbookURL` do not exist.

- [ ] **Step 3: Implement manifest and artifact model**

Add:

```swift
public enum ONTGenotypeWorkbookRevisionRole: String, Codable, CaseIterable, Equatable, Sendable {
    case initialCurrentCopy = "initial-current-copy"
    case imported
    case restored
    case externalEditSnapshot = "external-edit-snapshot"
}

public struct ONTGenotypeWorkbookRevision: Codable, Equatable, Sendable {
    public let id: String
    public let role: ONTGenotypeWorkbookRevisionRole
    public let path: String
    public let label: String
    public let sourceFilename: String?
    public let createdAt: String
    public let user: String?
    public let predecessorID: String?
    public let predecessorPath: String?
    public let sha256: String
    public let sizeBytes: Int64
    public let provenancePath: String?
}
```

Extend `ONTGenotypeResultBundleManifest` with optional `currentWorkbookPath` and `workbookRevisions`. Extend `ONTGenotypeResultArtifacts` with `primaryWorkbookURL`, keeping `workbookURL` as the current/editable workbook. Implement:

```swift
public static func currentWorkbookURL(for bundleURL: URL) throws -> URL {
    let manifest = try loadManifest(from: bundleURL)
    return resolvedURL(for: manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath, in: bundleURL)
}
```

Use `manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath` in `loadResult`.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
```

Expected: `ONTGenotypeResultBundleTests` pass.

### Task 2: New Pipeline Outputs Create Editable Current Workbook

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`

- [ ] **Step 1: Write the failing pipeline test**

Add:

```swift
func testRunCreatesSeparateCurrentWorkbookAndManifestKeepsPrimaryImmutable() async throws
```

Use `makeFakeONTGenotypingCondaRoot`. After running one small ONT request, assert:

```swift
let manifest = try ONTGenotypeResultBundle.loadManifest(from: outputDirectory)
XCTAssertEqual(manifest.primaryWorkbookPath, request.workbookURL.lastPathComponent)
XCTAssertEqual(manifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
let primary = try ONTGenotypeResultBundle.primaryWorkbookURL(for: outputDirectory)
let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: outputDirectory)
XCTAssertNotEqual(primary, current)
XCTAssertEqual(try Data(contentsOf: primary), try Data(contentsOf: current))
XCTAssertEqual(result.workbookURL, current)
XCTAssertEqual(manifest.workbookRevisions?.first?.role, .initialCurrentCopy)
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testRunCreatesSeparateCurrentWorkbookAndManifestKeepsPrimaryImmutable
```

Expected: failure because the manifest has no current workbook path and the pipeline returns the generated primary workbook.

- [ ] **Step 3: Implement current workbook creation**

Add `currentWorkbookURL` to `ONTBarcodeDemuxGenotypingRunRequest`:

```swift
public var currentWorkbookURL: URL {
    outputDirectory
        .appendingPathComponent("artifacts/workbooks", isDirectory: true)
        .appendingPathComponent("current.xlsx")
}
```

After `runReport`, copy `request.workbookURL` to `request.currentWorkbookURL`. Build an `initial-current-copy` revision with checksum and file size. Pass the revision into `writeProvenance` and `writeBundleManifest`. Keep `primaryWorkbookPath` pointing at `request.workbookURL`; set `currentWorkbookPath` to the relative current path. Return `result.workbookURL` as `request.currentWorkbookURL`.

Add a provenance step named `lungfish genotype workbook initial-current-copy` with inputs `[primary workbook]` and outputs `[current workbook]`.

- [ ] **Step 4: Run focused pipeline tests and verify GREEN**

Run:

```bash
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testRunCreatesSeparateCurrentWorkbookAndManifestKeepsPrimaryImmutable
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testRunWritesCompleteCanonicalProvenanceEnvelope
```

Expected: both pass after updating assertions that the returned workbook is now the current editable workbook and provenance includes both original and current workbook outputs.

### Task 3: Workbook Revision Service

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] **Step 1: Write failing revision tests**

Add tests:

```swift
func testImportRevisedWorkbookKeepsPrimaryAndSnapshotsPreviousCurrent() throws
func testImportMigratesOldPrimaryOnlyBundleBeforeReplacingCurrent() throws
func testImportRejectsNonXLSXWithoutChangingManifestOrCurrentWorkbook() throws
func testImportSnapshotsExternalEditBeforeManagedReplacement() throws
```

The tests create minimal bundles and ZIP-like `.xlsx` data beginning with `PK\u{3}\u{4}`. They assert that `primaryWorkbookPath` remains unchanged, `currentWorkbookPath` stays `artifacts/workbooks/current.xlsx`, previous current files are copied under `artifacts/workbooks/revisions/`, imported content replaces only current, and revision provenance paths exist.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter GenotypeWorkbookRevisionServiceTests
```

Expected: compile failure because the service does not exist.

- [ ] **Step 3: Implement revision service**

Implement:

```swift
public struct GenotypeWorkbookRevisionService: Sendable {
    public func ensureCurrentWorkbook(in bundleURL: URL) throws -> ONTGenotypeResultBundleManifest
    public func importRevisedWorkbook(
        from sourceURL: URL,
        into bundleURL: URL,
        label: String? = nil,
        user: String = NSUserName()
    ) throws -> ONTGenotypeResultBundleManifest
    public func restoreWorkbookRevision(
        id revisionID: String,
        in bundleURL: URL,
        user: String = NSUserName()
    ) throws -> ONTGenotypeResultBundleManifest
}
```

Validation checks extension `.xlsx` and ZIP magic bytes. `ensureCurrentWorkbook` migrates old bundles by copying primary to `artifacts/workbooks/current.xlsx` and writing an `initial-current-copy` revision. Imports snapshot the existing current workbook, detect and snapshot direct edits by comparing the latest current revision checksum, atomically replace current with the imported workbook, write sidecar provenance under `artifacts/workbooks/provenance/`, and atomically rewrite the manifest.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter GenotypeWorkbookRevisionServiceTests
swift test --filter ONTGenotypeResultBundleTests
```

Expected: all pass.

### Task 4: Per-Sample Illumina Mapping And Cohort Command Surface

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`
- Test: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationExecutionServiceTests.swift`

- [ ] **Step 1: Write failing tests**

Add a workflow regression:

```swift
func testIlluminaCohortMapsEachSampleWithSeparateMinimap2Invocation() async throws
```

Modify the fake minimap2 to append its argv to a log path from `LUNGFISH_FAKE_MINIMAP2_LOG` and fail if `-x sr` receives more than one query FASTQ after the reference. Run with three merged FASTQ bundles. Assert three minimap2 log lines, each has one staged `.sample-prefixed.fastq`, and provenance has three minimap2 steps.

Add CLI/app tests:

```swift
func testFastqCommandRegistersGenotypeCohort()
func testGenotypeCohortParsesIlluminaInputsWithoutBarcodes()
func testONTGenotypingArgumentsUseCohortCommandForMultipleIlluminaInputs()
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter 'ONTBarcodeDemuxGenotypingPipelineTests/testIlluminaCohortMapsEachSampleWithSeparateMinimap2Invocation|FastqGenotypingCommandTests|WorkflowOperationExecutionServiceTests/testONTGenotypingArgumentsUseCohortCommandForMultipleIlluminaInputs'
```

Expected: workflow test fails because one minimap2 invocation receives all staged FASTQs; CLI/app tests fail because `genotype-cohort` is not registered/routed.

- [ ] **Step 3: Implement per-sample mapping**

In `runMapping`, when `resolvedMode == .illuminaPaired && inputFASTQURLs.count > 1`:

1. Create `.amplicon-genotyping/mapping/`.
2. For each staged sample FASTQ, run minimap2 with exactly one query FASTQ and pipe to `samtools sort -o <support>/<sample>.sorted.bam -`.
3. Run `samtools merge -f <request.mappingBAMURL> <sample sorted BAMs...>`.
4. Run `samtools index <request.mappingBAMURL>`.
5. Record each minimap2/sort invocation plus the merge/index invocation in `MappingStepResult`.

Update legacy and canonical provenance to emit one minimap2 step per sample and a `samtools merge` step. Include temporary per-sample BAMs as transient alignment outputs before they are removed.

- [ ] **Step 4: Implement CLI/app cohort surface**

Add `FastqGenotypingCohortSubcommand` with command name `genotype-cohort`. It shares the same options as `FastqGenotypingSubcommand`, requires at least two inputs, constructs `ONTBarcodeDemuxGenotypingRunRequest(..., cliSubcommand: "genotype-cohort")`, and calls the same pipeline. Register it in `FastqCommand`.

Add `cliSubcommand` to `ONTBarcodeDemuxGenotypingRunRequest`, defaulting to `"genotype"`, and use it in `argv`.

Update `WorkflowOperationExecutionService.ontGenotypingArguments(for:)` so requests with multiple input FASTQ URLs and Illumina mode/read type serialize as:

```swift
["fastq", "genotype-cohort", ...]
```

Single-source and ONT barcode-demux runs keep `["fastq", "genotype", ...]`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter 'ONTBarcodeDemuxGenotypingPipelineTests/testIlluminaCohortMapsEachSampleWithSeparateMinimap2Invocation|ONTBarcodeDemuxGenotypingPipelineTests/testRunIlluminaModeConsumesPreparedSampleBundlesWithoutMergingReads|FastqGenotypingCommandTests|WorkflowOperationExecutionServiceTests'
```

Expected: all selected tests pass.

### Task 5: Display Uses Current Workbook And Shows Original

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: existing app/UI model tests if affected

- [ ] **Step 1: Write/adjust failing display assertions**

Add or update tests so fallback workbook preview uses `ONTGenotypeResultBundle.currentWorkbookURL(for:)`, and artifact rows include `"Workbook"` for current plus `"Original Workbook"` when the original differs.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter 'WorkflowOperationDialogStateTests|GenotypeResultViewportTests'
```

Expected: failure if rows/helpers still point only at primary.

- [ ] **Step 3: Implement display updates**

Change `genotypeResultWorkbookURL(forBundle:)` to call `currentWorkbookURL(for:)`. Add an "Original Workbook" artifact row when `result.artifacts.primaryWorkbookURL != result.artifacts.workbookURL`.

- [ ] **Step 4: Run display tests and verify GREEN**

Run:

```bash
swift test --filter 'WorkflowOperationDialogStateTests|GenotypeResultViewportTests'
```

Expected: pass.

### Task 6: Final Verification

**Files:** all touched files

- [ ] **Step 1: Run focused regression suite**

Run:

```bash
swift test --filter 'ONTBarcodeDemuxGenotypingPipelineTests|GenotypeWorkbookRevisionServiceTests|ONTGenotypeResultBundleTests|FastqGenotypingCommandTests|WorkflowOperationExecutionServiceTests|WorkflowOperationDialogStateTests|GenotypeResultViewportTests'
```

Expected: all pass, except existing `openpyxl`-dependent skips if the local environment still lacks openpyxl.

- [ ] **Step 2: Inspect provenance and manifests from tests**

Confirm generated `.lungfishgenotype` manifests include distinct `primaryWorkbookPath` and `currentWorkbookPath`, workbook revisions include checksums/sizes/provenance paths, and canonical provenance includes per-sample minimap2 invocations plus workbook copy/revision steps.

- [ ] **Step 3: Check worktree state**

Run:

```bash
git status --short
```

Expected: only intentional source/test/plan changes in the worktree.
