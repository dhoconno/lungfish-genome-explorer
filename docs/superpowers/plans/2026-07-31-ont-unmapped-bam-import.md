# ONT Unmapped BAM Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Import unmapped BAM files as single-end ONT reads by materializing a temporary `fastq.gz` and reusing the existing FASTQ recipe/import pipeline.

**Architecture:** Add a small source classifier shared by the CLI and app. The batch importer materializes BAM input inside its existing per-sample workspace, records conversion provenance, and otherwise leaves recipe and ingestion behavior unchanged. App routes accept BAM on the sequencing-read path and preselect ONT.

**Tech Stack:** Swift 6, AppKit, Swift Argument Parser, managed samtools/pigz, XCTest, Lungfish provenance envelopes.

---

### Task 1: Recognize BAM sequencing-read inputs

**Files:**
- Create: `Sources/LungfishIO/Formats/FASTQ/SequencingReadImportSource.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:254-390`
- Test: `Tests/LungfishIOTests/SequencingReadImportSourceTests.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`

- [x] **Step 1: Write failing classifier and discovery tests**

Add tests proving `.bam` is recognized case-insensitively, FASTQ recognition is unchanged, directory scanning returns one single-end sample per BAM, and `sample.bam` produces sample name `sample`.

```swift
XCTAssertTrue(SequencingReadImportSource.isBAM(URL(fileURLWithPath: "/tmp/sample.BAM")))
XCTAssertTrue(SequencingReadImportSource.isSupported(URL(fileURLWithPath: "/tmp/sample.fastq.gz")))
XCTAssertEqual(try FASTQBatchImporter.detectPairsFromDirectory(tempDir).map(\.sampleName), ["sample"])
```

- [x] **Step 2: Run the tests and confirm the BAM assertions fail**

Run: `swift test --filter 'SequencingReadImportSourceTests|FASTQBatchImporterTests'`

Expected: failure because the classifier does not exist and directory discovery ignores BAM.

- [x] **Step 3: Add the minimal shared classifier and use it during discovery**

```swift
public enum SequencingReadImportSource {
    public static func isBAM(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "bam"
    }

    public static func isSupported(_ url: URL) -> Bool {
        FASTQBundle.isFASTQFileURL(url) || isBAM(url)
    }
}
```

Use `isSupported` in flat and recursive batch discovery, and extend `fastqStem` to strip `.bam`.

- [x] **Step 4: Run the focused tests**

Run: `swift test --filter 'SequencingReadImportSourceTests|FASTQBatchImporterTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit the source-recognition slice**

```bash
git add Sources/LungfishIO/Formats/FASTQ/SequencingReadImportSource.swift Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishIOTests/SequencingReadImportSourceTests.swift Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift
git commit -m "feat: recognize BAM as ONT read input"
```

### Task 2: Materialize BAM as temporary compressed FASTQ

**Files:**
- Create: `Sources/LungfishWorkflow/Ingestion/ONTBAMImportMaterializer.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:769-1070`
- Test: `Tests/LungfishWorkflowTests/ONTBAMImportMaterializerTests.swift`

- [x] **Step 1: Write failing validation and command tests**

Cover: BAM requires `.ont`, BAM cannot have R2, FASTQ returns unchanged, conversion uses primary-read filter `0x900`, pigz uses the requested thread count, and missing/empty output fails.

```swift
XCTAssertThrowsError(try ONTBAMImportMaterializer.validate(pair: bamPair, platform: .illumina))
XCTAssertNoThrow(try ONTBAMImportMaterializer.validate(pair: bamPair, platform: .ont))
XCTAssertEqual(
    ONTBAMImportMaterializer.samtoolsArguments(input: bam, outputs: outputs),
    ["fastq", "-F", "2304", "-0", outputs.other.path, "-1", outputs.r1.path,
     "-2", outputs.r2.path, "-s", outputs.singletons.path, bam.path]
)
```

- [x] **Step 2: Run tests and confirm failure**

Run: `swift test --filter ONTBAMImportMaterializerTests`

Expected: failure because `ONTBAMImportMaterializer` does not exist.

- [x] **Step 3: Implement one materializer**

Create a materializer that:

```swift
public struct ONTBAMMaterialization: Sendable {
    public let processingPair: SamplePair
    public let provenanceSteps: [StepExecution]
}

public enum ONTBAMImportMaterializer {
    static func materialize(
        pair: SamplePair,
        platform: SequencingPlatform,
        workspace: URL,
        threads: Int,
        runner: NativeToolRunner = .shared
    ) async throws -> ONTBAMMaterialization
}
```

For FASTQ, return the original pair and no steps. For BAM, stream managed `samtools fastq -F 2304` into `workspace/<sample>.fastq`, compress it with managed `pigz -p <threads> -c`, verify non-empty `workspace/<sample>.fastq.gz`, and return a single-end processing pair. Capture the exact samtools and pigz process arguments plus shell-replay commands containing output redirection, versions, timing, status, stderr, input/output descriptors, and the original BAM as the scientific input. The stdout path is intentionally direct: it retains every primary read class without the sidecar-and-merge machinery needed by paired extraction workflows.

- [x] **Step 4: Insert materialization before recipe execution**

In `processSingleSample`, materialize immediately after workspace creation. Use `processingPair.r1/r2` for recipe and ingestion only; retain the original `pair` for naming, metadata, replay command, size reporting, and final top-level provenance.

- [x] **Step 5: Run materializer and importer tests**

Run: `swift test --filter 'ONTBAMImportMaterializerTests|FASTQBatchImporterTests'`

Expected: all selected tests pass.

- [x] **Step 6: Commit BAM materialization**

```bash
git add Sources/LungfishWorkflow/Ingestion/ONTBAMImportMaterializer.swift Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/ONTBAMImportMaterializerTests.swift
git commit -m "feat: materialize ONT BAM before FASTQ import"
```

### Task 3: Preserve BAM-first provenance

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:1262-1435`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterRecipeIntegrationTests.swift`

- [x] **Step 1: Write failing provenance tests**

Import a small BAM fixture through the real managed samtools/pigz/seqkit runtimes and assert the completed bundle contains:

```swift
XCTAssertEqual(envelope.inputs.first?.format, .bam)
XCTAssertTrue(envelope.argv.contains(bam.path))
XCTAssertTrue(envelope.steps.contains { $0.toolName == "samtools" && $0.argv.first == "samtools" })
XCTAssertTrue(envelope.steps.contains { $0.toolName == "pigz" && $0.exitStatus == 0 })
XCTAssertFalse(envelope.inputs.contains { $0.path.hasSuffix(".fastq.gz") && $0.role == .input })
```

- [x] **Step 2: Run tests and confirm the provenance format is wrong**

Run: `swift test --filter 'FASTQBatchImporterTests|FASTQBatchImporterRecipeIntegrationTests'`

Expected: the BAM input is absent or marked as FASTQ and conversion steps are absent.

- [x] **Step 3: Thread materialization steps into the provenance writer**

Pass `materialization.provenanceSteps` into `writeImportProvenance`, prepend them to recipe/ingestion steps, and choose descriptor format by source extension:

```swift
private static func provenanceFormat(for url: URL) -> ProvenanceFileFormat {
    SequencingReadImportSource.isBAM(url) ? .bam : .fastq
}
```

Add resolved options `sourceFormat`, `materializedInputFormat`, and `bamPrimaryReadFilter=2304`. Keep the durable replay command pointed at the BAM and `--platform ont`.

- [x] **Step 4: Run provenance tests**

Run: `swift test --filter 'FASTQBatchImporterTests|FASTQBatchImporterRecipeIntegrationTests'`

Expected: all selected tests pass and the BAM checksum/size is present in the final envelope.

- [x] **Step 5: Commit provenance support**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift Tests/LungfishWorkflowTests/FASTQBatchImporterRecipeIntegrationTests.swift
git commit -m "feat: record ONT BAM import provenance"
```

### Task 4: Route BAM through CLI and app ONT import

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+ImportCenter.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift`
- Modify: `Sources/LungfishApp/Services/SidebarImportPlanner.swift`
- Test: `Tests/LungfishCLITests/ImportFastqCommandTests.swift`
- Test: `Tests/LungfishAppTests/FASTQImportConfigurationTests.swift`
- Test: `Tests/LungfishAppTests/SidebarImportPlannerTests.swift`

- [x] **Step 1: Write failing routing tests**

Assert CLI BAM auto-detection returns `.ont`; Import Center accepts `.bam`; BAM drag/drop remains in the sequencing-read batch rather than the generic alignment import; and import-sheet platform detection returns Oxford Nanopore for BAM.

```swift
XCTAssertEqual(try ImportCommand.FastqSubcommand.detectPlatformFromPairs([bamPair]), .ont)
XCTAssertEqual(MainSplitViewController.detectedReadPlatform(for: [bamFilePair]), .oxfordNanopore)
XCTAssertEqual(SidebarImportPlanner.makePlan(for: [bam]).sourceURLs, [bam])
```

- [x] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter 'ImportFastqCommandTests|FASTQImportConfigurationTests|SidebarImportPlannerTests'`

Expected: BAM is ignored/routed as alignment and platform detection does not return ONT.

- [x] **Step 3: Add the narrow routing changes**

- Change CLI help to “FASTQ or unmapped ONT BAM”, include BAM during directory scanning, and return `.ont` before reading a FASTQ header when the first input is BAM.
- Add `.bam` to the Import Center sequencing-read card and update its plain-language label.
- Collect supported read inputs with `SequencingReadImportSource.isSupported` in Import Center and sidebar drop routing.
- Preserve ordinary BAM alignment import when the user chooses the dedicated BAM/CRAM alignment card; the sequencing-read action and direct project drop use ONT BAM read import.
- Detect BAM in `presentFASTQImportSheet` and preselect `.oxfordNanopore`.

- [x] **Step 4: Run routing tests**

Run: `swift test --filter 'ImportFastqCommandTests|FASTQImportConfigurationTests|SidebarImportPlannerTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit routing support**

```bash
git add Sources/LungfishCLI/Commands/ImportFastqCommand.swift Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift Sources/LungfishApp/App/AppDelegate+ImportCenter.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift Sources/LungfishApp/Services/SidebarImportPlanner.swift Tests/LungfishCLITests/ImportFastqCommandTests.swift Tests/LungfishAppTests/FASTQImportConfigurationTests.swift Tests/LungfishAppTests/SidebarImportPlannerTests.swift
git commit -m "feat: expose ONT BAM read import"
```

### Task 5: End-to-end verification and documentation

**Files:**
- Modify: `docs/user-manual/chapters/03-reads/01-importing-fastq.md`
- Modify: `docs/superpowers/plans/2026-07-31-ont-unmapped-bam-import.md`

- [x] **Step 1: Run the focused suites**

Run: `swift test --filter 'SequencingReadImportSourceTests|ONTBAMImportMaterializerTests|FASTQBatchImporterTests|FASTQBatchImporterRecipeIntegrationTests|ImportFastqCommandTests|FASTQImportConfigurationTests|SidebarImportPlannerTests'`

Expected: all selected tests pass.

- [x] **Step 2: Run the CLI integration test with a generated BAM fixture**

Run: `swift test --filter FASTQBatchImportTests/testONTBAMImportProducesFASTQBundleWithBAMProvenanceAndCleansWorkspace`

Expected: the test imports a small BAM fixture and verifies one `.lungfishfastq` bundle whose primary payload is `fastq.gz` and whose final provenance input is the BAM. The importer intentionally does not reject mapped records because BAM is treated as a read container here.

- [x] **Step 3: Verify cleanup**

Confirm the completed project contains no `fastq-import-*` workspace and no temporary `.fastq`/`.fastq.gz` outside the published bundle.

- [x] **Step 4: Update user documentation**

Document that unmapped BAM is available on the sequencing-read import card, is treated as single-end ONT, and is converted temporarily before recipes run.

- [x] **Step 5: Run the broader build and tests**

Run: `swift test`, followed by the focused BAM/import suites.

Result: the full build succeeds and all BAM/import suites pass. The otherwise unrelated `FileSystemWatcherTests.searchIndexWritesDoNotFeedBackIntoWatcher` remains red because it reports the search service's temporary provenance filename; rerunning that test alone reproduces the same pre-existing failure.

- [x] **Step 6: Commit verification documentation**

```bash
git add docs Tests/LungfishWorkflowTests/ONTBAMImportEndToEndTests.swift
git commit -m "docs: describe ONT BAM read import"
```
