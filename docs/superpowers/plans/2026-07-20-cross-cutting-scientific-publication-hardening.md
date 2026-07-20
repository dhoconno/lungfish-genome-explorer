# Cross-Cutting Scientific Publication Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the highest-value shared scientific integrity risks by hardening SQLite publication, FASTQ parsing, process execution, provenance coverage, and test teardown immediately, then introduce durable bundle/payload/provenance transactions as a separately reviewed later tranche.

**Architecture:** The immediate tranche strengthens existing central boundaries without changing scientific bundle schemas: `SQLiteDatabasePublication`, a new strict raw FASTQ stream, and `NativeToolRunner`. Source-level coverage tests prevent future bypasses. The later tranche adds descriptor-relative filesystem operations, an immutable recovery journal, a cross-process bundle mutation lock, and input generation attestations; payload, manifest, and provenance caller migration begins only after the primitive passes crash/race review.

**Tech Stack:** Swift 6, Swift Package Manager/XCTest, Foundation `Process`, Darwin `openat`/`renameat`/`flock`/`fsync`, SQLite3, ArgumentParser, Codable JSON, FASTQ/gzip streams, macOS APFS and ExFAT-compatible publication.

---

## Scope guardrails

- Do not change genotype interpretation, MHC candidate naming, workbook content, or viewport behavior.
- Do not add feature-specific exceptions to central publication helpers.
- Treat missing completed provenance as a blocking scientific defect.
- Do not delete a SQLite WAL after a failed or busy checkpoint.
- Do not accept malformed/truncated FASTQ in strict demultiplexing paths.
- Do not begin caller migration to the later transaction layer until its crash, race, and ambiguity tests pass and an independent reviewer approves the primitive.
- Use the current feature worktree and preserve unrelated Task 16 edits.
- Build and launch `Lungfish Debug` after each completed immediate source-code changeset. The test-only teardown commit does not require an app rebuild.

## Work-window allocation

| Tranche | Work | Estimate | Overnight status |
|---|---|---:|---|
| Immediate A | Bound test teardown | 0.5–1 h | Required |
| Immediate B | SQLite publisher and NVD failure propagation | 4–6 h | Required |
| Immediate C | Strict raw FASTQ stream and exact-demux migration | 3–5 h | Required if time permits |
| Immediate D | Safe generic process output, two migrations, bypass guard | 3–4 h | Stop/go after C |
| Immediate E | Exact CLI leaf provenance coverage | 2–4 h | Stretch goal |
| Later | Durable scientific publication transaction and migrations | 14–24 h | Separate coordinated tranche |

## Immediate tranche file map

### New files

- `Tests/LungfishIOTests/SQLiteDatabasePublicationTests.swift` — checkpoint, integrity, publication fallback, race, and recovery tests.
- `Sources/LungfishWorkflow/Metagenomics/NVDUniqueReadPopulator.swift` — checked SQLite/samtools enrichment separated from import orchestration.
- `Tests/LungfishWorkflowTests/Metagenomics/NVDUniqueReadPopulatorTests.swift` — explicit failure and rollback behavior.
- `Sources/LungfishIO/Formats/FASTQ/FASTQRawRecordStream.swift` — strict raw four-line record stream.
- `Tests/LungfishIOTests/FASTQRawRecordStreamTests.swift` — malformed, gzip, multi-file, and cancellation coverage.
- `Tests/LungfishWorkflowTests/ScientificProcessExecutionBoundaryTests.swift` — source guard against unapproved direct `Process()`.

### Modified files

- `Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift`
- `Sources/LungfishIO/Formats/Common/SQLiteDatabasePublication.swift`
- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`
- `Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift`
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- `Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift`
- `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift`
- `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`
- `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`

## Later coordinated tranche file map

### New files

- `Sources/LungfishIO/Filesystem/FilesystemIdentity.swift`
- `Sources/LungfishIO/Filesystem/DirectoryHandle.swift`
- `Sources/LungfishIO/Filesystem/DurableGenerationPublisher.swift`
- `Sources/LungfishIO/Bundles/BundleMutationCoordinator.swift`
- `Sources/LungfishWorkflow/Provenance/ScientificPublicationTransaction.swift`
- `Sources/LungfishWorkflow/Provenance/ProvenanceInputAttestation.swift`
- `Tests/LungfishIOTests/DurableGenerationPublisherTests.swift`
- `Tests/LungfishIOTests/BundleMutationCoordinatorTests.swift`
- `Tests/LungfishWorkflowTests/ScientificPublicationTransactionTests.swift`
- `Tests/LungfishWorkflowTests/ProvenanceInputAttestationTests.swift`

### Modified files after primitive approval

- `Sources/LungfishWorkflow/Provenance/ProvenancePublicationSnapshot.swift`
- `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`
- `Sources/LungfishWorkflow/Bundles/ReferenceBundleAnnotationImportService.swift`
- `Sources/LungfishWorkflow/SequenceAnnotation/SequenceAnnotationTrackWorkflow.swift`
- `Sources/LungfishWorkflow/Alignment/PreparedAlignmentAttachmentService.swift`
- `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`
- `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
- `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`

---

## Immediate A — Restore trustworthy aggregate verification

### Task 1: Bound cross-process publication-lock test teardown

**Estimate:** 30–60 minutes

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift:747-774,1542-1579`

- [ ] **Step 1: Add a failing wedged-child cleanup test**

Add a `CrossProcessPublicationLockHolder` initializer flag that makes the child ignore the release sentinel, then test explicit bounded cleanup:

```swift
func testCrossProcessPublicationLockHolderCleanupIsBounded() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let artifacts = fixture.outputURL.appendingPathComponent("artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

    let holder = try CrossProcessPublicationLockHolder(
        artifactsDirectoryURL: artifacts,
        ignoresRelease: true
    )
    let start = ContinuousClock.now
    XCTAssertThrowsError(try holder.close(timeout: .milliseconds(250)))
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    XCTAssertFalse(holder.isRunning)
}
```

- [ ] **Step 2: Run the focused suite and confirm the new test times out or cannot compile**

Run:

```bash
swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests
```

Expected: FAIL because `close(timeout:)`, `ignoresRelease`, and `isRunning` do not exist.

- [ ] **Step 3: Replace blocking `release()`/`deinit` with explicit bounded cleanup**

Use this public shape inside the private test helper:

```swift
func close(timeout: Duration = .seconds(2)) throws {
    guard !released else { return }
    released = true
    FileManager.default.createFile(atPath: releaseURL.path, contents: Data())
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning, ContinuousClock.now < deadline {
        usleep(10_000)
    }
    if process.isRunning {
        ProcessTreeTerminator.terminate(rootProcess: process)
    }
    guard !process.isRunning else { throw CleanupTimeout() }
}

deinit {
    if process.isRunning { process.terminate() }
}
```

Change the contention test to `defer { try? heldLock.close() }`. Do not call `waitUntilExit()` from `deinit`.

- [ ] **Step 4: Run the full cohort-alignment suite with a wall-clock bound**

Run:

```bash
/usr/bin/time -p swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests
```

Expected: PASS and the command exits without manual interruption.

- [ ] **Step 5: Commit the isolated test-infrastructure fix**

```bash
git add Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift
git commit -m "test: bound cross-process lock holder cleanup"
```

### Stop/go checkpoint A

Go only if the aggregate cohort-alignment suite exits reliably three consecutive times. If it still hangs, stop hardening work long enough to capture the remaining child PID and stack; do not normalize a focused-only test gate.

---

## Immediate B — Make SQLite publication durable and explicit

### Task 2: Specify SQLite publication invariants with failure-injection tests

**Estimate:** 1–1.5 hours

**Files:**
- Create: `Tests/LungfishIOTests/SQLiteDatabasePublicationTests.swift`
- Modify: `Sources/LungfishIO/Formats/Common/SQLiteDatabasePublication.swift` only to expose internal injectable collaborators after tests fail

- [ ] **Step 1: Write tests for checkpoint failure and WAL preservation**

Create a test collaborator protocol and assert that failed checkpoint does not remove sidecars:

```swift
func testFailedCheckpointPreservesAuthoritativeWAL() throws {
    let fixture = try SQLitePublicationFixture(journalMode: "WAL")
    defer { fixture.remove() }
    try Data("authoritative".utf8).write(to: fixture.stagingWALURL)

    XCTAssertThrowsError(
        try SQLiteDatabasePublication.publish(
            stagingURL: fixture.stagingURL,
            to: fixture.finalURL,
            system: FailingSQLitePublicationSystem(checkpointCode: SQLITE_BUSY)
        )
    )
    XCTAssertEqual(try Data(contentsOf: fixture.stagingWALURL), Data("authoritative".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
}
```

- [ ] **Step 2: Add tests for integrity, ExFAT fallback, and destination races**

Add these exact cases:

```swift
func testQuickCheckFailureDoesNotPublish() throws
func testUnsupportedSwapUsesExclusiveReservationGenerationRotation() throws
func testFallbackNeverOverwritesRacedDestination() throws
func testSuccessfulPublishReopensFinalDatabaseAndRetainsRows() throws
func testRetiredGenerationIsRemovedOnlyAfterFinalValidation() throws
func testSymlinkStagingOrDestinationIsRejected() throws
```

The fallback race fixture must create an unrelated destination after the simulated `ENOTSUP` result and assert its bytes remain unchanged.

- [ ] **Step 3: Run the focused tests and confirm failure**

Run:

```bash
swift test --filter SQLiteDatabasePublicationTests
```

Expected: FAIL because publication has no injectable system, does not report checkpoint/quick-check errors, and has no ExFAT-safe fallback.

### Task 3: Implement checked, ExFAT-compatible SQLite publication

**Estimate:** 2.5–3.5 hours

**Files:**
- Modify: `Sources/LungfishIO/Formats/Common/SQLiteDatabasePublication.swift`
- Test: `Tests/LungfishIOTests/SQLiteDatabasePublicationTests.swift`
- Regression tests: `Tests/LungfishIOTests/AnnotationDatabaseTests.swift`
- Regression tests: `Tests/LungfishIOTests/VariantDatabaseTests.swift`

- [ ] **Step 1: Add typed failure cases and the injectable system boundary**

Use typed errors so callers and provenance can distinguish the operation:

```swift
enum SQLiteDatabasePublicationError: Error, LocalizedError, Equatable {
    case unsafeArtifact(String)
    case checkpointFailed(path: String, code: Int32, message: String)
    case journalModeFailed(path: String, observed: String)
    case integrityCheckFailed(path: String, result: String)
    case synchronizationFailed(path: String, code: Int32)
    case destinationOccupied(String)
    case publishFailed(String)
    case finalValidationFailed(String)
}
```

The injected system owns SQLite open/checkpoint/pragma/quick-check, `lstat`, `fsync`, rename attempts, and exclusive reservation. Production defaults call SQLite3 and Darwin directly.

- [ ] **Step 2: Replace unchecked checkpoint/removal with a checked preparation phase**

Implement a preparation function with this contract:

```swift
private static func prepareForPublication(
    _ url: URL,
    system: any SQLitePublicationSystem
) throws {
    try system.requireRegularFileNoFollow(url)
    try system.checkpointWAL(url, mode: SQLITE_CHECKPOINT_TRUNCATE)
    let journalMode = try system.setJournalModeDelete(url)
    guard journalMode.caseInsensitiveCompare("delete") == .orderedSame else {
        throw SQLiteDatabasePublicationError.journalModeFailed(
            path: url.path,
            observed: journalMode
        )
    }
    guard try system.quickCheck(url) == "ok" else {
        throw SQLiteDatabasePublicationError.integrityCheckFailed(
            path: url.path,
            result: try system.quickCheck(url)
        )
    }
    try system.synchronizeFile(url)
}
```

Do not remove `-wal` or `-shm` after any thrown operation. After successful DELETE transition, remove only empty/stale sidecars whose identity was captured during preparation.

- [ ] **Step 3: Publish as an attested generation**

Attempt `RENAME_SWAP` for an existing final file and exclusive rename for an absent final file. On `ENOTSUP`, create an exclusive adjacent reservation, attest it, rotate `final -> retired`, `staging -> final`, and recover `retired -> final` if the second move fails. Every move must refuse replacement of an unowned entry.

Record the actual mechanism in the returned result:

```swift
enum SQLitePublicationMechanism: String, Sendable {
    case renameSwap = "rename-swap"
    case exclusiveRename = "exclusive-rename"
    case exclusiveReservationGenerationRotation = "exclusive-reservation-generation-rotation"
}

struct SQLitePublicationResult: Sendable {
    let mechanism: SQLitePublicationMechanism
    let finalURL: URL
}
```

- [ ] **Step 4: Reopen and validate before retiring the old generation**

Run `quick_check` through a fresh connection at the final path, fsync the parent directory, then remove the attested retired generation. If cleanup fails after validation, return a result carrying the retained retired path rather than invalidating the scientific publication.

- [ ] **Step 5: Run focused and caller regression tests**

Run:

```bash
swift test --filter SQLiteDatabasePublicationTests
swift test --filter AnnotationDatabaseTests
swift test --filter VariantDatabaseTests
```

Expected: PASS.

### Task 4: Make NVD enrichment failures explicit

**Estimate:** 1–1.5 hours

**Files:**
- Create: `Sources/LungfishWorkflow/Metagenomics/NVDUniqueReadPopulator.swift`
- Create: `Tests/LungfishWorkflowTests/Metagenomics/NVDUniqueReadPopulatorTests.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:716-725,2191-2381`

- [ ] **Step 1: Write failure and rollback tests**

```swift
func testUpdateStepFailureRollsBackAndThrowsSQLiteError() async throws
func testCommitFailureRollsBackAndThrowsSQLiteError() async throws
func testSamtoolsFailureIsReturnedInFailedStepAndThrows() async throws
func testMissingOptionalBAMIsReportedAsSkippedNotSQLiteSuccess() async throws
func testSuccessfulPopulationCommitsEveryCountedRow() async throws
```

The first two tests must query the database afterward and prove that no partial `unique_reads` updates committed.

- [ ] **Step 2: Run tests and confirm current behavior fails**

```bash
swift test --filter NVDUniqueReadPopulatorTests
```

Expected: FAIL because the current private function returns zero rows for errors.

- [ ] **Step 3: Extract a throwing populator**

Use an outcome that separates legitimate skips from errors:

```swift
struct NVDUniqueReadPopulationResult: Sendable {
    let updatedRows: Int
    let skippedRows: [NVDUniqueReadSkippedRow]
    let steps: [NvdAuxiliaryStep]
}

enum NVDUniqueReadPopulationError: Error, LocalizedError {
    case sqlite(operation: String, message: String)
    case samtools(accession: String, stderr: String)
}
```

Check every `sqlite3_bind_*`, `sqlite3_step`, `BEGIN`, `COMMIT`, and `ROLLBACK` result. Any update failure rolls back the complete transaction and throws.

- [ ] **Step 4: Preserve failure telemetry in provenance**

At the import call site, append the failed samtools/SQLite step and rethrow so the outer workflow records a failed run. Do not publish a completed NVD bundle with partially populated unique-read counts.

- [ ] **Step 5: Run NVD and metagenomics import tests**

```bash
swift test --filter NVDUniqueReadPopulatorTests
swift test --filter MetagenomicsImport
```

Expected: PASS.

- [ ] **Step 6: Commit Immediate B**

```bash
git add Sources/LungfishIO/Formats/Common/SQLiteDatabasePublication.swift \
  Sources/LungfishWorkflow/Metagenomics/NVDUniqueReadPopulator.swift \
  Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift \
  Tests/LungfishIOTests/SQLiteDatabasePublicationTests.swift \
  Tests/LungfishWorkflowTests/Metagenomics/NVDUniqueReadPopulatorTests.swift
git commit -m "fix: harden scientific SQLite publication"
```

- [ ] **Step 7: Build and launch the debug app**

Run:

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
/usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
open -n build/Debug/Lungfish.app
```

Expected: every command exits zero and the launched app menu name is `Lungfish Debug`.

### Stop/go checkpoint B

Go only if all SQLite failure-injection tests prove that an interrupted publication retains a valid complete old or complete new database and never deletes authoritative WAL content. If the fallback cannot meet that invariant, stop rather than shipping an APFS-only partial fix.

---

## Immediate C — Centralize strict raw FASTQ parsing

### Task 5: Add a strict raw FASTQ record stream

**Estimate:** 1.5–2 hours

**Files:**
- Create: `Sources/LungfishIO/Formats/FASTQ/FASTQRawRecordStream.swift`
- Create: `Tests/LungfishIOTests/FASTQRawRecordStreamTests.swift`
- Reference: `Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift:200-351`

- [ ] **Step 1: Write strict structural tests**

```swift
func testReadsValidFourLineRecordAndPreservesRawText() async throws
func testRejectsHeaderWithoutAtSignAtExactLine() async throws
func testRejectsSeparatorWithoutPlusAtExactLine() async throws
func testRejectsSequenceQualityLengthMismatch() async throws
func testRejectsTruncatedRecordAtEOF() async throws
func testRejectsTruncationAtMultiFileBoundary() async throws
func testReadsGzipInput() async throws
func testConsumerCancellationStopsProducer() async throws
```

Use a typed error:

```swift
enum FASTQRawRecordStreamError: Error, LocalizedError, Equatable {
    case invalidHeader(url: URL, line: Int)
    case invalidSeparator(url: URL, line: Int)
    case qualityLengthMismatch(url: URL, line: Int, sequence: Int, quality: Int)
    case truncatedRecord(url: URL, firstLine: Int, observedLines: Int)
}
```

- [ ] **Step 2: Run tests and confirm failure**

```bash
swift test --filter FASTQRawRecordStreamTests
```

Expected: FAIL because the stream does not exist.

- [ ] **Step 3: Implement the minimal strict stream**

Expose this shape:

```swift
public struct FASTQRawRecord: Sendable, Equatable {
    public let header: String
    public let sequence: String
    public let separator: String
    public let quality: String
    public let sourceURL: URL
    public let firstLineNumber: Int

    public var identifier: String {
        String(header.dropFirst()).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    }

    public var serialized: String {
        [header, sequence, separator, quality].joined(separator: "\n") + "\n"
    }
}

public struct FASTQRawRecordStream: Sendable {
    public init(urls: [URL]) throws
    public func records() -> AsyncThrowingStream<FASTQRawRecord, Error>
}
```

Validate every completed record before yielding. Do not carry a partial record from one URL into the next. Wire `continuation.onTermination` to cancel the producer task.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter FASTQRawRecordStreamTests
```

Expected: PASS.

### Task 6: Migrate exact-barcode demultiplexing to the strict stream

**Estimate:** 1.5–3 hours

**Files:**
- Modify: `Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift:246-347`
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift:1867-1913,2015-2073`
- Test: `Tests/LungfishWorkflowTests/ExactBarcodeDemuxTests.swift`
- Test: `Tests/LungfishWorkflowTests/DemultiplexingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift`

- [ ] **Step 1: Add failing workflow-level corruption tests**

```swift
func testExactDemuxRejectsTruncatedInputWithoutReturningCounts() async throws
func testExactDemuxRejectsMalformedSeparatorWithoutPublishingBundles() async throws
func testShardedBareBarcodeDemuxRejectsMalformedChunk() async throws
func testUnshardedBareBarcodeDemuxRejectsQualityMismatch() async throws
```

Each test must assert that no completed output bundle or completed provenance exists.

- [ ] **Step 2: Replace hand-built `lineBuffer` loops**

Use:

```swift
for try await raw in try FASTQRawRecordStream(urls: inputURLs).records() {
    let record = FASTQRawRecord(
        header: raw.header,
        sequence: raw.sequence,
        separator: raw.separator,
        quality: raw.quality
    )
    // Existing assignment and accumulation logic remains unchanged.
}
```

Remove warning-only trailing-line handling. Do not change barcode matching, trimming, sample IDs, read weighting, or output formatting.

- [ ] **Step 3: Run focused and integration tests**

```bash
swift test --filter FASTQRawRecordStreamTests
swift test --filter ExactBarcodeDemuxTests
swift test --filter DemultiplexingPipelineTests
swift test --filter DemultiplexPipelineIntegrationTests
```

Expected: PASS with unchanged counts for all valid fixtures.

- [ ] **Step 4: Commit Immediate C**

```bash
git add Sources/LungfishIO/Formats/FASTQ/FASTQRawRecordStream.swift \
  Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift \
  Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift \
  Tests/LungfishIOTests/FASTQRawRecordStreamTests.swift \
  Tests/LungfishWorkflowTests/ExactBarcodeDemuxTests.swift \
  Tests/LungfishWorkflowTests/DemultiplexingPipelineTests.swift \
  Tests/LungfishWorkflowTests/DemultiplexPipelineIntegrationTests.swift
git commit -m "fix: reject malformed FASTQ during demultiplexing"
```

- [ ] **Step 5: Rebuild and launch `Lungfish Debug`**

Run:

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
/usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
open -n build/Debug/Lungfish.app
```

Expected: build and checks exit zero. Open an existing well-formed FASTQ bundle read-only and confirm it loads without triggering a transform.

### Stop/go checkpoint C

Go only if every valid fixture retains its exact previous read/sample counts and malformed fixtures fail before publication. If wrapped FASTQ appears in a valid demultiplex fixture, stop and decide whether raw-record preservation or wrapped-input normalization is authoritative; do not silently flatten it.

---

## Immediate D — Enforce one safe scientific process boundary

### Task 7: Add generic executable file-output execution to `NativeToolRunner`

**Estimate:** 1.5–2 hours

**Files:**
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Test: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`

- [ ] **Step 1: Write large-output, cancellation, and launch-failure tests**

```swift
func testRunProcessWithFileOutputDrainsLargeStderrConcurrently() async throws
func testRunProcessWithFileOutputStreamsBinaryStdoutExactly() async throws
func testRunProcessWithFileOutputCancellationTerminatesDescendant() async throws
func testRunProcessWithFileOutputFailureLeavesNoPublishedFinalFile() async throws
```

Generate at least 1 MiB on stdout and 1 MiB on stderr in the same child so the test exceeds pipe capacity decisively.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
swift test --filter NativeToolRunnerTests
```

Expected: FAIL because the generic file-output API does not exist.

- [ ] **Step 3: Implement the generic streamed output API**

```swift
public func runProcessWithFileOutput(
    executableURL: URL,
    arguments: [String],
    outputFile: URL,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil,
    toolName: String? = nil,
    maxStderrBytes: Int = 1_048_576
) async throws -> NativeToolResult
```

Create the output at an adjacent staging path with no-follow exclusive creation, pass the open handle as stdout, drain stderr concurrently using the existing accumulator, and reuse `ProcessCancellationState`. Move staging to the requested output only after exit zero and file synchronization. Return exact executable plus arguments in `NativeToolResult.arguments`.

- [ ] **Step 4: Run `NativeToolRunnerTests`**

Expected: PASS.

### Task 8: Migrate confirmed deadlock-prone callers and add a bypass guard

**Estimate:** 1.5–2 hours

**Files:**
- Modify: `Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift:379-429`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:132-175`
- Create: `Tests/LungfishWorkflowTests/ScientificProcessExecutionBoundaryTests.swift`
- Test: existing reference import and mapping summary tests

- [ ] **Step 1: Add noisy subprocess regression tests**

The reference decompressor fixture writes >1 MiB stderr while producing a valid output. The mapping summary fixture writes interleaved >1 MiB stdout/stderr. Both tests use a finite timeout and must complete.

- [ ] **Step 2: Migrate reference decompression**

Inject or construct `NativeToolRunner`, call `runProcessWithFileOutput`, and translate a nonzero result into `ReferenceBundleImportError.decompressionFailed` using bounded stderr. Preserve the exact decompressor argv for the enclosing import provenance.

- [ ] **Step 3: Migrate mapping summary**

Call `NativeToolRunner.runProcess` for `samtools view`; remove the custom continuation, sequential pipe reads, and timeout work item. Preserve the existing `MappingSummaryBuilderError.samtoolsViewFailed` mapping.

- [ ] **Step 4: Add the source boundary test**

```swift
func testScientificWorkflowSourcesDoNotCreateUnapprovedProcessInstances() throws {
    let allowedSuffixes: Set<String> = [
        "Native/NativeToolRunner.swift",
        "Native/ProcessTreeTerminator.swift",
        "Containers/ContainerProcess.swift",
        "ProcessManager.swift",
        "Engines/DockerRuntime.swift",
        "Engines/AppleContainerRuntime.swift",
        "Engines/ContainerRuntimeFactory.swift",
        "Conda/CondaManager.swift",
        "Variants/GATKPipelineExecutor.swift",
    ]
    let observedDebt = try sourceFiles(under: "Sources/LungfishWorkflow")
        .filter { try String(contentsOf: $0).contains("Process()") }
        .filter { file in !allowedSuffixes.contains(where: file.path.hasSuffix) }
        .map(sourceRelativePath)
        .sorted()
    XCTAssertEqual(observedDebt, Self.knownLegacyProcessDebt.sorted())
}

private static let knownLegacyProcessDebt = [
    "Sources/LungfishWorkflow/ApplicationExports/ApplicationExportImportCollectionService.swift",
    "Sources/LungfishWorkflow/Conda/CondaOfflinePackService.swift",
    "Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift",
    "Sources/LungfishWorkflow/FASTQ/CountedFASTQMaterializer.swift",
    "Sources/LungfishWorkflow/Geneious/GeneiousArchiveTool.swift",
    "Sources/LungfishWorkflow/Geneious/GeneiousImportCollectionService.swift",
    "Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift",
    "Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift",
    "Sources/LungfishWorkflow/Metagenomics/CzId/CzIdImportPreview.swift",
    "Sources/LungfishWorkflow/Metagenomics/EsVirituDatabaseManager.swift",
    "Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift",
    "Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift",
    "Sources/LungfishWorkflow/Metagenomics/NaoMgsSamplePartitioner.swift",
    "Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift",
    "Sources/LungfishWorkflow/Native/ToolProvisioning/ToolProvisioner.swift",
    "Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCAlignmentProcessRunner.swift",
    "Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift",
    "Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift",
    "Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift",
    "Sources/LungfishWorkflow/ONTGenotyping/ONTPacBioBarcodeDemuxMaterializer.swift",
    "Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift",
    "Sources/LungfishWorkflow/TwelveS/TwelveSResultExportWorkflow.swift",
]
```

Check in an explicit `knownLegacyProcessDebt` list. The test fails if a new path appears; later commits shrink the list. Do not create a blanket regex exemption.

- [ ] **Step 5: Run process, reference import, mapping, and boundary tests**

```bash
swift test --filter NativeToolRunnerTests
swift test --filter ReferenceBundleImport
swift test --filter MappingSummary
swift test --filter ScientificProcessExecutionBoundaryTests
```

Expected: PASS and the debt list is smaller by the two migrated files.

- [ ] **Step 6: Commit Immediate D and rebuild debug**

```bash
git add Sources/LungfishWorkflow/Native/NativeToolRunner.swift \
  Sources/LungfishWorkflow/Bundles/ReferenceBundleImportService.swift \
  Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift \
  Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift \
  Tests/LungfishWorkflowTests/ScientificProcessExecutionBoundaryTests.swift
git commit -m "fix: centralize scientific process execution"
```

Run:

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
/usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
open -n build/Debug/Lungfish.app
```

Expected: all commands exit zero.

### Stop/go checkpoint D

If fewer than three hours remain before handoff, stop after Immediate D, run the final immediate verification matrix, and document leaf-provenance work as pending. Do not rush a partial policy inventory.

---

## Immediate E — Make provenance coverage leaf-exact

### Task 9: Require exact policy for every scientific CLI leaf

**Estimate:** 2–4 hours

**Files:**
- Modify: `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift:60-181`
- Modify: `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift:51-87`

- [ ] **Step 1: Add recursive command inventory helpers and failing tests**

```swift
func testEveryScientificLeafCommandHasExactPathPolicy() {
    let leaves = recursiveLeafPaths(LungfishCLI.configuration)
    let missing = leaves.filter {
        ScientificProvenancePolicy.exactCLICommand(path: $0) == nil
    }
    XCTAssertEqual(missing, [])
}

func testExactLeafPoliciesContainNoStalePaths() {
    let leaves = Set(recursiveLeafPaths(LungfishCLI.configuration).map { $0.joined(separator: " ") })
    XCTAssertEqual(
        Set(ScientificProvenancePolicy.cliCommandPathPolicies.keys).subtracting(leaves),
        []
    )
}

func testDataWritingLeafPoliciesDeclareWriterAndFinalPayloadExpectation() {
    for policy in ScientificProvenancePolicy.cliCommandPathPolicies.values
        where policy.workflowKind == .dataWriting {
        XCTAssertFalse(policy.writer.isEmpty)
        XCTAssertEqual(policy.outputPathExpectation, .finalStoredPayload)
        XCTAssertTrue(policy.requiresProvenance)
    }
}
```

- [ ] **Step 2: Run coverage and confirm missing leaf policies**

```bash
swift test --filter ScientificCLIProvenanceCoverageTests
```

Expected: FAIL with a deterministic sorted list of missing paths.

- [ ] **Step 3: Add exact policies in bounded command groups**

Add policies for one top-level group at a time, classifying every leaf—including version, environment-management, and debug leaves—as data-writing, metadata-only, or inspect-only and naming the concrete writer where provenance is required. Never use `CLIProvenanceSupport` as the writer label for a leaf that actually uses a specialized publisher.

Expose an exact lookup that does not fall back:

```swift
public static func exactCLICommand(path: [String]) -> ProvenancePolicyEntry? {
    cliCommandPathPolicies[canonicalCommandPath(path)]
}
```

Run the coverage test after each group so classification mistakes have a small diff.

- [ ] **Step 4: Add negative fixture coverage**

Define a test-only command tree containing one unregistered output-writing leaf and prove the inventory reports it. This prevents the inventory helper itself from silently omitting nested commands.

- [ ] **Step 5: Run CLI provenance and fast release gates**

```bash
swift test --filter ScientificCLIProvenanceCoverageTests
swift test --filter ProvenanceBuilderTests
swift test --filter ProvenanceFailurePolicySourceTests
```

Expected: PASS.

- [ ] **Step 6: Commit Immediate E**

```bash
git add Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift \
  Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift
git commit -m "test: require leaf-level scientific provenance policy"
```

---

## Immediate tranche completion gate

### Task 10: Verify, review, document, and rebuild

**Estimate:** 1–2 hours

**Files:**
- None. Record verification commands and results in the task handoff; do not add another design document.

- [ ] **Step 1: Run all immediate focused suites from a clean build invocation**

```bash
swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests
swift test --filter SQLiteDatabasePublicationTests
swift test --filter NVDUniqueReadPopulatorTests
swift test --filter FASTQRawRecordStreamTests
swift test --filter ExactBarcodeDemuxTests
swift test --filter DemultiplexingPipelineTests
swift test --filter NativeToolRunnerTests
swift test --filter ScientificProcessExecutionBoundaryTests
swift test --filter ScientificCLIProvenanceCoverageTests
```

Expected: PASS; no test command requires manual termination.

- [ ] **Step 2: Run feature-regression suites**

Run:

```bash
swift test --filter FullLengthONTMHCGenotypingPipelineTests
swift test --filter ONTGenotypeResultBundleTests
swift test --filter GenotypeWorkbookRevisionServiceTests
swift test --filter GenotypeResultViewportTests
```

Expected: the same test counts and pass status as immediately before hardening.

- [ ] **Step 3: Request two independent reviews**

Review A covers scientific integrity and provenance requirements. Review B covers filesystem/crash/concurrency behavior. Resolve every P0/P1 finding before claiming readiness.

- [ ] **Step 4: Build and launch the final debug app**

Run:

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
/usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
open -n build/Debug/Lungfish.app
```

Expected: all commands exit zero and a new debug app process starts.

Launch against the validated candidate-debug bundle, not the original July 19 result.

- [ ] **Step 5: Record exact deferred work**

Report which of Immediate C–E completed, the commit hashes, test commands/counts, and the unstarted later-transaction tasks. Do not describe a deferred tranche as implemented.

---

## Later coordinated tranche — Durable scientific publication transactions

The following tasks are intentionally not part of the overnight minimum. Start only after the immediate completion gate and the later-tranche go criteria in the design.

### Task 11: Add descriptor-relative filesystem identity and generation publication

**Estimate:** 4–6 hours

**Files:**
- Create: `Sources/LungfishIO/Filesystem/FilesystemIdentity.swift`
- Create: `Sources/LungfishIO/Filesystem/DirectoryHandle.swift`
- Create: `Sources/LungfishIO/Filesystem/DurableGenerationPublisher.swift`
- Create: `Tests/LungfishIOTests/DurableGenerationPublisherTests.swift`

- [ ] **Step 1: Write identity, symlink, race, and ExFAT fallback tests**

```swift
func testIdentityUsesLstatAndRejectsSymlink() throws
func testOpenChildNoFollowRejectsSymlinkAncestor() throws
func testExclusivePublishNeverOverwritesRacedEntry() throws
func testGenerationRotationRestoresOldGenerationWhenSecondMoveFails() throws
func testParentIdentityChangeAbortsEveryMove() throws
func testCleanupRemovesOnlyAttestedRetiredGeneration() throws
```

- [ ] **Step 2: Implement focused primitives**

```swift
public struct FilesystemIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt16
    public let size: UInt64
}

public final class DirectoryHandle: @unchecked Sendable {
    public static func openNoFollow(_ url: URL) throws -> DirectoryHandle
    public func identity() throws -> FilesystemIdentity
    public func openChildNoFollow(_ name: String, flags: Int32) throws -> Int32
    public func renameNoReplace(_ source: String, to destination: String) throws
    public func synchronize() throws
}
```

`DurableGenerationPublisher` owns swap/exclusive-reservation fallback and returns final/retired identities plus the actual mechanism.

- [ ] **Step 3: Run tests and request filesystem safety review**

Do not proceed to Task 12 until the reviewer confirms there is no flags-zero overwrite race, parent identity is bound, and cleanup is attestation-limited.

### Task 12: Add immutable journal and crash recovery

**Estimate:** 4–6 hours

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ScientificPublicationTransaction.swift`
- Create: `Tests/LungfishWorkflowTests/ScientificPublicationTransactionTests.swift`

- [ ] **Step 1: Write crash-point and ambiguity tests**

```swift
func testCrashAfterJournalPreservesOldGenerationAndPreparedStage() throws
func testCrashAfterRetiringOldCompletesOrRestoresUsingAttestations() throws
func testCrashAfterPublishingNewFinalizesNewGeneration() throws
func testManualEditAfterPrepareCausesAmbiguityAndNoDeletion() throws
func testCorruptJournalCausesAmbiguityAndNoDeletion() throws
func testRecoveryIsIdempotent() throws
```

- [ ] **Step 2: Define immutable schema**

```swift
public struct ScientificPublicationJournal: Codable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let rootIdentity: FilesystemIdentity
    public let finalParentIdentity: FilesystemIdentity
    public let oldGeneration: PublicationGeneration?
    public let stagedGeneration: PublicationGeneration
    public let finalRelativePath: String
    public let retiredRelativePath: String
}
```

The journal has no mutable phase. Publish it once through an owned exclusive reservation; recovery infers state from attested entries.

- [ ] **Step 3: Implement prepare/commit/recover/finalize**

Every operation revalidates the root and final-parent identities. Recovery deletes only a directory/file whose current identity equals a journal attestation. An unknown identity returns `ambiguousTransaction` with retained paths.

- [ ] **Step 4: Run crash tests and request independent safety review**

Stop if the implementation depends on rewriting journal phase, unowned destination replacement, or unattested cleanup.

### Stop/go checkpoint F: transaction primitive approval

Caller migration is prohibited until Tasks 11–12 pass all failure-injection tests and an independent reviewer returns APPROVED. A BLOCKED review returns work to the primitive; it is not waived because happy-path tests pass.

### Task 13: Publish payload and provenance as one generation

**Estimate:** 3–5 hours

**Files:**
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenancePublicationSnapshot.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`
- Test: `Tests/LungfishWorkflowTests/ScientificPublicationTransactionTests.swift`
- Test: `Tests/LungfishWorkflowTests/ProvenanceSigningTests.swift`
- Test: `Tests/LungfishWorkflowTests/ProvenanceTests.swift`

- [ ] **Step 1: Add multi-artifact/signing crash tests**

Cover root provenance, rollup, focused output sidecars, signature, public key, stale-sidecar pruning, and payload manifest in one generation. Kill injection after each write must expose either the old or new complete set.

- [ ] **Step 2: Stage the complete provenance layout**

Change `ProvenanceWriter` so it can render a complete layout beneath a caller-provided staging root without mutating final paths. The transaction inventories and hashes the staged payload plus provenance before commit.

- [ ] **Step 3: Deprecate destructive snapshot restore**

Retain `ProvenancePublicationSnapshot` temporarily as a compatibility adapter backed by the transaction. Remove its system-temporary copy/remove/copy implementation. No new caller may instantiate a nontransactional snapshot.

- [ ] **Step 4: Verify signed and unsigned recovery**

Run provenance, signing, and transaction suites. Verify signatures reference final relative paths and validate after recovery.

### Task 14: Add cross-process bundle mutation coordination and migrate one vertical slice

**Estimate:** 4–6 hours

**Files:**
- Create: `Sources/LungfishIO/Bundles/BundleMutationCoordinator.swift`
- Create: `Tests/LungfishIOTests/BundleMutationCoordinatorTests.swift`
- Modify first: `Sources/LungfishWorkflow/Bundles/ReferenceBundleAnnotationImportService.swift`
- Test: `Tests/LungfishAppTests/ReferenceBundleAnnotationImportServiceTests.swift`

- [ ] **Step 1: Write same-process and separate-process lost-update tests**

Two mutations begin from the same manifest. The coordinator must serialize or reject stale generation, and the final manifest must contain both committed tracks when operations are retried correctly. A failing mutation must not remove the successful mutation’s payload or provenance.

- [ ] **Step 2: Implement lock plus generation precondition**

```swift
public final class BundleMutationCoordinator: @unchecked Sendable {
    public static func acquire(for bundleURL: URL) throws -> BundleMutationCoordinator
    public func currentManifestGeneration() throws -> BundleManifestGeneration
    public func commit(
        expected: BundleManifestGeneration,
        prepared: PreparedScientificPublication
    ) throws -> ScientificPublicationResult
    public func close()
}
```

The adjacent lock file uses no-follow exclusive open plus `flock`. The manifest generation contains checksum, size, and filesystem identity.

- [ ] **Step 3: Migrate annotation import as the pilot**

Acquire before reading the manifest, stage the annotation database and complete manifest/provenance generation, then commit once. Remove stale-manifest rollback and private provenance snapshot code.

- [ ] **Step 4: Run pilot tests and independent review**

Only after the pilot passes should separate plans migrate `SequenceAnnotationTrackWorkflow`, `PreparedAlignmentAttachmentService`, and `BundleVariantTrackAttachmentService` in small commits.

### Task 15: Attest inputs before execution

**Estimate:** 3–5 hours

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceInputAttestation.swift`
- Create: `Tests/LungfishWorkflowTests/ProvenanceInputAttestationTests.swift`
- Modify: `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`

- [ ] **Step 1: Write input replacement/edit tests**

```swift
func testUnchangedInputUsesPreExecutionChecksum() throws
func testInPlaceEditIsRejectedAtCompletion() throws
func testAtomicReplacementWithSameSizeIsRejected() throws
func testSymlinkRetargetIsRejected() throws
func testImmutableSnapshotRecordsSourceToFinalStoredPayloadRelationship() throws
```

- [ ] **Step 2: Implement attestation capture and verification**

```swift
public struct ProvenanceInputAttestation: Codable, Sendable {
    public let descriptor: ProvenanceFileDescriptor
    public let identity: FilesystemIdentity
    public static func capture(_ url: URL, format: FileFormat?) throws -> Self
    public func verifyUnchanged() throws
}
```

Permit a verified local attestation to be added verbatim to `ProvenanceRunBuilder`. Keep rejecting arbitrary caller-created local descriptors.

- [ ] **Step 3: Add begin/complete API to CLI provenance support**

Capture inputs before the tool starts and pass attestations into completion. If verification fails, record a failed run with `inputChangedDuringExecution`; do not publish successful provenance for the changed path.

- [ ] **Step 4: Migrate one direct CLI command and verify GUI rehydration**

Use `fastq qc-summary` as the pilot because it has an existing publication snapshot and focused provenance tests. Confirm a GUI import points provenance at the final stored payload, not staging.

### Task 16: Later-tranche completion gate

**Estimate:** 2–3 hours

- [ ] Run all transaction, filesystem, provenance, signing, annotation-import, and input-attestation suites.
- [ ] Run adversarial races on APFS and the real ExFAT validation volume using only a disposable test bundle.
- [ ] Verify every manifest-declared payload and provenance checksum after fresh commit and recovery.
- [ ] Obtain independent scientific-integrity and filesystem-safety approvals.
- [ ] Run `scripts/build-app.sh --configuration debug`, verify `CFBundleName` and `CFBundleIdentifier` with `/usr/bin/plutil`, verify signing with `/usr/bin/codesign --verify --deep --strict --verbose=4`, and launch with `open -n build/Debug/Lungfish.app`.
- [ ] Document actual publication mechanisms observed on APFS and ExFAT.
- [ ] Commit each migrated vertical slice separately; do not combine generic primitive and all caller migrations in one commit.

## Final self-review checklist

- Every immediate task produces a usable, testable improvement without depending on the later tranche.
- No task changes MHC science or UI semantics.
- SQLite WAL deletion is conditional on proven checkpoint/journal transition.
- FASTQ tolerant behavior is never implicit.
- Process guardrails allow known legacy debt but reject new debt.
- Leaf provenance coverage uses exact command paths.
- The later journal is immutable and binds root plus final-parent identities.
- Recovery never deletes unattested or ambiguous generations.
- Provenance describes final stored payloads and pre-execution input generations.
- All stop/go checkpoints state when work must pause instead of broadening scope.
