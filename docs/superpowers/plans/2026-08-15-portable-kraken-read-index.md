# Portable Kraken Read Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Kraken2 read extraction work from SILVA and other analyses stored on ExFAT, preserve compatibility with existing WAL-formatted indexes, and report an accurate batch extraction estimate.

**Architecture:** Continue using WAL only while bulk-building an index, then require a successful checkpoint and convert the finished database to `journal_mode=DELETE` so the artifact is self-contained. Open legacy databases immutably only when their WAL is absent or empty, never when it contains pending frames. If an index cannot answer a query, log the failure and stream the original Kraken output. Estimate batch counts by loading each selected sample's classification result. Existing extraction provenance remains authoritative and unchanged.

**Tech Stack:** Swift 6, SQLite3 C API, Foundation, OSLog, XCTest, Swift Package Manager, Xcode Debug build.

---

## Task 1: Make Kraken indexes portable and legacy indexes readable

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken/KrakenIndexDatabase.swift`
- Test: `Tests/LungfishIOTests/KrakenIndexDatabaseTests.swift`

- [ ] **Step 1: Add a failing test that finished builds are standalone**

Add `import SQLite3` to the test file and add a helper that opens an index read-only and evaluates `PRAGMA journal_mode`. Add this behavior test:

```swift
func testBuildFinalizesStandaloneDeleteJournalDatabase() throws {
    try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

    XCTAssertEqual(try journalMode(at: indexURL), "delete")
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path + "-shm"))
}
```

- [ ] **Step 2: Run the standalone build test and confirm RED**

Run:

```bash
swift test --filter KrakenIndexDatabaseTests/testBuildFinalizesStandaloneDeleteJournalDatabase
```

Expected: failure because the current builder leaves the database header in WAL mode.

- [ ] **Step 3: Add a failing legacy empty-WAL compatibility test**

Create a real index, use SQLite to put it into WAL mode, close it, create an adjacent zero-byte `-wal`, ensure `-shm` is absent, then open it through `KrakenIndexDatabase` and query a known taxon:

```swift
func testLegacyEmptyWALIndexOpensWithoutCreatingSharedMemory() throws {
    try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
    try convertToLegacyWALHeader(indexURL)
    FileManager.default.createFile(atPath: indexURL.path + "-wal", contents: Data())
    try? FileManager.default.removeItem(atPath: indexURL.path + "-shm")

    let db = try KrakenIndexDatabase(url: indexURL)
    defer { db.close() }
    XCTAssertEqual(try db.readIds(forTaxIds: [562]), ["read1", "read3"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path + "-shm"))
}
```

The fixture helper must create real SQLite state rather than mocking SQLite. Confirm the file header is WAL formatted before the read.

- [ ] **Step 4: Run the legacy test and confirm RED**

Run:

```bash
swift test --filter KrakenIndexDatabaseTests/testLegacyEmptyWALIndexOpensWithoutCreatingSharedMemory
```

Expected: failure because the current reader uses a normal read-only open, which requires WAL shared-memory handling.

- [ ] **Step 5: Implement explicit read-only open policy**

In `KrakenIndexDatabase`, add a private helper returning an open target and flags. If `index.sqlite-wal` is absent or has exactly zero bytes, construct a percent-safe `file:` URI with `immutable=1` and include `SQLITE_OPEN_URI`; if the WAL cannot be inspected or has nonzero size, use the ordinary file path and ordinary read-only flags.

```swift
private static func readOnlyOpenConfiguration(for url: URL) -> (String, Int32) {
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    let attributes = try? FileManager.default.attributesOfItem(atPath: walURL.path)
    let walIsSafe = attributes == nil || (attributes?[.size] as? NSNumber)?.int64Value == 0
    guard walIsSafe, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return (url.path, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
    }
    components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    return (components.string ?? url.absoluteString,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI)
}
```

Use the same helper in `init(url:)` and `isValid(at:for:)`. Do not use immutable mode when a WAL contains data because those frames may be uncheckpointed.

- [ ] **Step 6: Make query completion errors observable**

After each `readIds` step loop, require `SQLITE_DONE`; otherwise throw `KrakenIndexDatabaseError.openFailed("Query failed: ...")`. This prevents partial results or I/O errors from being mistaken for a successful query.

- [ ] **Step 7: Require portable finalization after building**

Replace the ignored checkpoint with checked operations:

```swift
let checkpointRC = sqlite3_wal_checkpoint_v2(
    db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil
)
guard checkpointRC == SQLITE_OK else {
    throw KrakenIndexDatabaseError.buildFailed(
        "WAL checkpoint failed: \(String(cString: sqlite3_errmsg(db)))"
    )
}
guard executeJournalModeDelete(db) == "delete" else {
    throw KrakenIndexDatabaseError.buildFailed("Failed to disable WAL journal mode")
}
```

Return locking to normal before switching journal modes if SQLite requires it. The helper must prepare `PRAGMA journal_mode = DELETE`, step to `SQLITE_ROW`, read and lowercase the returned mode, finalize the statement, and surface errors. Update the build documentation to state that the completed artifact uses DELETE mode.

- [ ] **Step 8: Run the index test class and confirm GREEN**

Run:

```bash
swift test --filter KrakenIndexDatabaseTests
```

Expected: all tests pass, including the two new regressions.

- [ ] **Step 9: Commit Task 1**

```bash
git add Sources/LungfishIO/Formats/Kraken/KrakenIndexDatabase.swift Tests/LungfishIOTests/KrakenIndexDatabaseTests.swift
git commit -m "fix: make Kraken read indexes portable"
```

## Task 2: Fall back when an index query fails

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/TaxonomyExtractionTests.swift`

- [ ] **Step 1: Add an end-to-end failing fallback test**

Build a valid raw Kraken classification file and matching FASTQ with a selected taxon. Place a real SQLite file at `KrakenIndexDatabase.indexURL(for:)` that opens successfully but cannot execute `SELECT read_id FROM reads` (for example, a valid SQLite schema without the `reads` table). Run the public extraction API and assert that the matching raw-classification reads are extracted:

```swift
func testExtractFallsBackToRawKrakenOutputWhenIndexQueryFails() async throws {
    let classOutput = try makeClassificationOutput(reads: [
        (readId: "read1", taxId: 562, classified: true),
        (readId: "read2", taxId: 1280, classified: true),
    ])
    try createReadableButUnqueryableIndex(at: KrakenIndexDatabase.indexURL(for: classOutput))
    let fastqURL = try makeFASTQ(reads: ["read1", "read2"])
    let outputURL = tempDir.appendingPathComponent("fallback.fastq.gz")
    let config = TaxonomyExtractionConfig(
        taxIds: [562], includeChildren: false, sourceFile: fastqURL,
        outputFile: outputURL, classificationOutput: classOutput
    )

    let result = try await TaxonomyExtractionPipeline()
        .extract(config: config, tree: makeTestTree()).first!
    XCTAssertEqual(result.readCount, 1)
}
```

Use the real extraction path and its existing test runtime; do not add a test-only production API.

- [ ] **Step 2: Run the fallback test and confirm RED**

Run:

```bash
swift test --filter TaxonomyExtractionPipelineTests/testExtractFallsBackToRawKrakenOutputWhenIndexQueryFails
```

Expected: it throws `Failed to open Kraken index database: Query failed: no such table: reads` instead of streaming the raw file.

- [ ] **Step 3: Catch index open and query failures at one boundary**

Refactor `buildReadIdSet` so the open, capability check, and `readIds` call are inside `do/catch`. Return indexed IDs only after a successful query; otherwise log the index URL and error and proceed to the existing raw `.kraken`/`.kraken.gz` reader.

```swift
if FileManager.default.fileExists(atPath: indexURL.path) {
    do {
        let index = try KrakenIndexDatabase(url: indexURL)
        defer { index.close() }
        if index.canResolve(taxIds: targetTaxIds) {
            let readIds = try index.readIds(forTaxIds: targetTaxIds)
            progress?(0.30, "Loaded \(readIds.count) read IDs from Kraken2 index")
            return normalizeReadIds(readIds, keepReadPairs: keepReadPairs)
        }
    } catch {
        logger.warning(
            "Kraken index query failed at \(indexURL.path, privacy: .public); "
                + "falling back to raw classification output: "
                + "\(String(describing: error), privacy: .public)"
        )
    }
}
```

The fallback must not rewrite the index or classification output.

- [ ] **Step 4: Run the pipeline test class and confirm GREEN**

Run:

```bash
swift test --filter TaxonomyExtractionPipelineTests
```

Expected: all pipeline tests pass and the new regression extracts one read.

- [ ] **Step 5: Confirm provenance remains complete**

Run the existing extraction provenance tests in the same class. Confirm the final output path, input identities/checksums/sizes, workflow/tool version, argv, explicit options/resolved defaults, runtime, wall time, exit status, and stderr fields still pass. The fallback changes ID resolution only; it must not bypass provenance recording.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift Tests/LungfishWorkflowTests/Metagenomics/TaxonomyExtractionTests.swift
git commit -m "fix: fall back from unusable Kraken indexes"
```

## Task 3: Correct batch Kraken extraction estimates

**Files:**
- Modify: `Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift`
- Test: `Tests/LungfishWorkflowTests/Extraction/ClassifierReadResolverTests.swift`

- [ ] **Step 1: Add a failing batch fixture estimate test**

Use the committed `kraken2-mini` fixture. Treat its parent as the batch root and identify the fixture by sample ID:

```swift
func testEstimateKraken2ReadCountLoadsPerSampleBatchResult() async throws {
    let sampleResult = try kraken2MiniResultPath()
    let classResult = try ClassificationResult.load(from: sampleResult)
    let taxon = try XCTUnwrap(
        classResult.tree.allNodes().first { $0.taxId != 0 && $0.readsClade > 0 }
    )
    let estimate = try await ClassifierReadResolver().estimateReadCount(
        tool: .kraken2,
        resultPath: sampleResult.deletingLastPathComponent(),
        selections: [ClassifierRowSelector(
            sampleId: sampleResult.lastPathComponent,
            accessions: [], taxIds: [taxon.taxId]
        )],
        options: ExtractionOptions()
    )
    XCTAssertEqual(estimate, taxon.readsClade)
}
```

Use the actual public `estimateReadCount(tool:resultPath:selections:options:)` entry point shown above.

- [ ] **Step 2: Run the estimate test and confirm RED**

Run:

```bash
swift test --filter ClassifierReadResolverTests/testEstimateKraken2ReadCountLoadsPerSampleBatchResult
```

Expected: actual value is zero because the resolver tries to load the batch root.

- [ ] **Step 3: Load and total each selected sample**

Implement `estimateKraken2ReadCount` using `groupBySample(selections)`. For a non-nil sample ID, load `resultPath.appendingPathComponent(sampleId, isDirectory: true)`; for the single-sample case, load `resultPath`. Build target IDs per group and add matching `readsClade` values to the total. A failed sample load remains best-effort: log it and contribute zero without discarding successful samples.

- [ ] **Step 4: Run resolver tests and confirm GREEN**

Run:

```bash
swift test --filter ClassifierReadResolverTests
```

Expected: all tests pass and the fixture estimate equals its selected clade count.

- [ ] **Step 5: Commit Task 3**

```bash
git add Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift Tests/LungfishWorkflowTests/Extraction/ClassifierReadResolverTests.swift
git commit -m "fix: estimate Kraken reads per batch sample"
```

## Task 4: Integrate, validate the reported analysis, and build the debug app

**Files:**
- Verify: `Sources/LungfishIO/Formats/Kraken/KrakenIndexDatabase.swift`
- Verify: `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift`
- Verify: `Sources/LungfishWorkflow/Extraction/ClassifierReadResolver.swift`
- Verify read-only analysis: `/Volumes/iWES_WNPRC/32521/32531-All.lungfish/Analyses/kraken2-batch-2026-08-14T23-01-25`
- Build output: `build/Debug/Lungfish.app`

- [ ] **Step 1: Run all focused regression suites together**

```bash
swift test --filter KrakenIndexDatabaseTests
swift test --filter TaxonomyExtractionPipelineTests
swift test --filter ClassifierReadResolverTests
```

Record test counts and elapsed results.

- [ ] **Step 2: Validate a real SILVA legacy index without modifying it**

Choose one per-sample `classification.kraken.gz.idx.sqlite` under the reported analysis. Record checksums and sidecar sizes before the check. Use the built code or a minimal read-only executable path to open the index and query a taxonomy ID present in that sample. Confirm the query succeeds, the main-file checksum is unchanged, and no `-shm` or nonempty `-wal` is created. Do not rebuild or rewrite any of the 56 analysis indexes.

- [ ] **Step 3: Verify raw fallback and output provenance through an integration extraction**

Run one small extraction from a fixture or a copied test analysis into a fresh `mktemp -d` destination. Confirm the result contains reads and its provenance sidecar/envelope names the extraction workflow and version, reproducible argv, explicit and resolved options, runtime identity, source and output paths/checksums/sizes, success status, wall time, and useful stderr. Move the temporary verification directory to Trash afterward. Never use the live analysis as an output destination.

- [ ] **Step 4: Run broader checks**

```bash
swift test
git diff --check
git status --short
```

If the full suite has unrelated pre-existing failures, distinguish them with focused passing evidence; do not hide or rewrite unrelated changes.

- [ ] **Step 5: Build a testable Debug app**

Inspect and use the repository's canonical Debug build script or Xcode invocation. Build the app to:

```text
build/Debug/Lungfish.app
```

Capture the build log and verify the executable exists, the bundle is Debug-configured, and the app can launch far enough for a smoke check without mutating the user's analysis.

- [ ] **Step 6: Request specification and code-quality reviews**

Use fresh reviewers. First verify exact compliance with the design and this plan; then review maintainability, safety of SQLite URI/path handling, nonempty-WAL behavior, fallback correctness, provenance preservation, and test quality. Address every confirmed finding with tests and rerun affected suites.

- [ ] **Step 7: Final verification and handoff**

Run final focused tests, `git diff --check`, and inspect `git status`. Report the root cause, changed behavior, real-analysis read-only validation, provenance evidence, Debug app path, build/test evidence, commits, and any residual limitations. Do not claim the existing SILVA indexes were rewritten.
