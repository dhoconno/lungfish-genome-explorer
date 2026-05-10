# FASTQ Operations Test Harness & Shared Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable test framework for verifying FASTQ derivative operations, fix the trim preview bug, add 6 missing CLI subcommands (including `materialize`), and refactor GUI materialization to use CLI.

**Architecture:** Two test layers (unit with mocks, integration with real tools) sharing a common `FASTQOperationTestHelper`. The `lungfish fastq materialize` CLI command replaces in-process materialization logic. Five additional CLI subcommands fill gaps for operations that currently lack CLI backing.

**Tech Stack:** Swift 6.2, XCTest, ArgumentParser, seqkit, fastp, bbtools, cutadapt

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift` | Shared test assertion utilities |
| Create | `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift` | Unit tests for preview/trim/materialization logic |
| Create | `Tests/LungfishIntegrationTests/FASTQOperationIntegrationTests.swift` | Integration tests with real tools |
| Create | `Sources/LungfishCLI/Commands/FastqMaterializeSubcommand.swift` | `lungfish fastq materialize` CLI |
| Create | `Sources/LungfishCLI/Commands/FastqSearchTextSubcommand.swift` | `lungfish fastq search-text` CLI |
| Create | `Sources/LungfishCLI/Commands/FastqSearchMotifSubcommand.swift` | `lungfish fastq search-motif` CLI |
| Create | `Sources/LungfishCLI/Commands/FastqOrientSubcommand.swift` | `lungfish fastq orient` CLI |
| Create | `Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift` | `lungfish fastq scrub-human` CLI |
| Create | `Sources/LungfishCLI/Commands/FastqSequenceFilterSubcommand.swift` | `lungfish fastq sequence-filter` CLI |
| Modify | `Sources/LungfishCLI/Commands/FastqCommand.swift` | Register new subcommands + make helpers `internal` |
| Modify | `Sources/LungfishApp/Services/FASTQDerivativeService.swift:679-746` | Add preview.fastq for trim ops (bug fix) |
| Modify | `Sources/LungfishApp/Services/FASTQDerivativeService.swift:1876-2000` | Refactor materialization to call CLI |

---

### Task 1: Shared Test Helper

**Files:**
- Create: `Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift`

- [ ] **Step 1: Create the test helper file**

```swift
import XCTest
import Foundation
@testable import LungfishIO

/// Shared utilities for FASTQ operation round-trip tests.
struct FASTQOperationTestHelper {

    // MARK: - Temp Directory

    static func makeTempDir(prefix: String = "FASTQOpTest") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Bundle Creation

    static func makeBundle(
        named name: String,
        in tempDir: URL,
        fastqFilename: String = "reads.fastq"
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = tempDir.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent(fastqFilename)
        return (bundleURL, fastqURL)
    }

    // MARK: - Synthetic FASTQ Writing

    /// Writes deterministic FASTQ records with Phred-33 quality scores.
    static func writeSyntheticFASTQ(
        to url: URL,
        readCount: Int = 100,
        readLength: Int = 150,
        idPrefix: String = "read"
    ) throws {
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<readCount {
            let id = "\(idPrefix)\(i + 1)"
            var seq = ""
            for j in 0..<readLength {
                seq.append(bases[(i + j) % 4])
            }
            let qual = String(repeating: "I", count: readLength)
            lines.append(contentsOf: ["@\(id)", seq, "+", qual])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes specific FASTQ records from tuples.
    static func writeFASTQ(records: [(id: String, sequence: String)], to url: URL) throws {
        let lines: [String] = records.flatMap { record in
            [
                "@\(record.id)",
                record.sequence,
                "+",
                String(repeating: "I", count: record.sequence.count),
            ]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - FASTQ Reading

    static func loadFASTQRecords(from url: URL) async throws -> [FASTQRecord] {
        let reader = FASTQReader(validateSequence: false)
        var records: [FASTQRecord] = []
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    // MARK: - Assertions

    /// Asserts that preview.fastq exists in a bundle and contains valid, parseable reads.
    static func assertPreviewValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: previewURL.path),
            "preview.fastq missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let records = try await loadFASTQRecords(from: previewURL)
        XCTAssertGreaterThan(
            records.count, 0,
            "preview.fastq has 0 reads in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }

    /// Asserts the manifest payload matches the expected type.
    static func assertPayloadType(
        bundleURL: URL,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            XCTFail("No manifest in \(bundleURL.lastPathComponent)", file: file, line: line)
            return
        }
        let payloadDescription: String
        switch manifest.payload {
        case .subset: payloadDescription = "subset"
        case .trim: payloadDescription = "trim"
        case .full: payloadDescription = "full"
        case .fullPaired: payloadDescription = "fullPaired"
        case .fullMixed: payloadDescription = "fullMixed"
        case .fullFASTA: payloadDescription = "fullFASTA"
        case .demuxedVirtual: payloadDescription = "demuxedVirtual"
        case .demuxGroup: payloadDescription = "demuxGroup"
        case .orientMap: payloadDescription = "orientMap"
        }
        XCTAssertEqual(
            payloadDescription, expected,
            "Expected payload \(expected), got \(payloadDescription)",
            file: file, line: line
        )
    }

    /// Asserts trim-positions.tsv exists and has valid content.
    static func assertTrimPositionsValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let trimURL = bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trimURL.path),
            "trim-positions.tsv missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let positions = try FASTQTrimPositionFile.load(from: trimURL)
        XCTAssertFalse(
            positions.isEmpty,
            "trim-positions.tsv is empty in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }

    /// Asserts read-ids.txt exists and has valid content.
    static func assertSubsetIDsValid(
        bundleURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let readIDURL = bundleURL.appendingPathComponent("read-ids.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readIDURL.path),
            "read-ids.txt missing in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
        let content = try String(contentsOf: readIDURL, encoding: .utf8)
        let ids = content.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(
            ids.count, 0,
            "read-ids.txt is empty in \(bundleURL.lastPathComponent)",
            file: file, line: line
        )
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds (the helper is used by tests, not the main target)

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/Support/FASTQOperationTestHelper.swift
git commit -m "test: add FASTQOperationTestHelper with shared assertion utilities"
```

---

### Task 2: Fix Trim Preview Bug — Failing Test

**Files:**
- Create: `Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift`

The bug: `createDerivative()` in FASTQDerivativeService.swift only writes `preview.fastq` for subset operations (line 738) and orient operations (line 969). Trim operations (qualityTrim, adapterTrim, fixedTrim, primerRemoval) write `trim-positions.tsv` but never write `preview.fastq`. The viewport calls `resolvePrimaryFASTQURL` which scans for FASTQ files in the bundle — finding none, it shows nothing.

- [ ] **Step 1: Write the failing test**

This test creates a root bundle with known reads, manually simulates what `createDerivative` does for a trim operation (writes a trim-positions.tsv but no preview), then checks for preview.fastq. It will fail because the current code doesn't write one.

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class FASTQOperationRoundTripTests: XCTestCase {

    // MARK: - Trim Preview Bug

    /// Verifies that trim derivatives include a preview.fastq file.
    /// This tests the bug where trim operations only wrote trim-positions.tsv
    /// but not preview.fastq, causing the viewport to show nothing.
    func testTrimDerivativeBundleContainsPreviewFASTQ() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "TrimPreviewTest")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a root bundle with known reads
        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 50,
            readLength: 100,
            idPrefix: "read"
        )

        // Create a derived bundle that mimics what createDerivative does for trim ops:
        // - writes trim-positions.tsv
        // - does NOT write preview.fastq (the bug)
        let derived = try FASTQOperationTestHelper.makeBundle(named: "trimmed", in: tempDir)

        // Write trim positions: every read trimmed by 10 from each end
        var trimRecords: [FASTQTrimRecord] = []
        for i in 0..<50 {
            trimRecords.append(FASTQTrimRecord(
                readID: "read\(i + 1)#0",
                trimStart: 10,
                trimEnd: 90
            ))
        }
        let trimURL = derived.bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        try FASTQTrimPositionFile.write(trimRecords, to: trimURL)

        // The bundle should have a preview.fastq for the viewport to display.
        // This assertion WILL FAIL — proving the bug exists.
        let previewURL = derived.bundleURL.appendingPathComponent("preview.fastq")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: previewURL.path),
            "Trim derivative bundle is missing preview.fastq — viewport will show nothing"
        )
    }

    /// Verifies that fixed trim preview reads are shorter than originals by the expected amount.
    /// Uses the full createDerivative flow (requires seqkit + fastp).
    func testFixedTrimPreviewReadsAreTrimmed() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FixedTrimInteg")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: 50,
            readLength: 100,
            idPrefix: "read"
        )

        let service = FASTQDerivativeService()
        let derivedURL = try await service.createDerivative(
            from: root.bundleURL,
            request: .fixedTrim(from5Prime: 10, from3Prime: 10),
            progress: nil
        )

        // Assert preview exists and is valid
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)

        // Assert trim positions file exists
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        // Assert preview reads are trimmed (80bp, not 100bp)
        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        let previewRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: previewURL)
        for record in previewRecords {
            XCTAssertEqual(
                record.sequence.count, 80,
                "Preview read \(record.identifier) should be 80bp after 10+10 trim, got \(record.sequence.count)bp"
            )
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FASTQOperationRoundTripTests 2>&1 | tail -20`
Expected: Both tests FAIL — `testTrimDerivativeBundleContainsPreviewFASTQ` fails with "missing preview.fastq", `testFixedTrimPreviewReadsAreTrimmed` fails similarly (or with tool error if fastp unavailable).

- [ ] **Step 3: Commit the failing tests**

```bash
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "test: add failing tests for trim derivative preview.fastq bug"
```

---

### Task 3: Fix Trim Preview Bug — Implementation

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift:679-746`

The fix: after writing `trim-positions.tsv`, also write `preview.fastq` from the trimmed FASTQ output (the `transformedFASTQ` variable). This is the same call used in the subset branch.

- [ ] **Step 1: Add preview.fastq generation to the trim branch**

In `FASTQDerivativeService.swift`, find the trim branch (around line 700-720) that ends with:
```swift
    let trimFilename = FASTQBundle.trimPositionFilename
    let trimURL = outputBundle.appendingPathComponent(trimFilename)
    try FASTQTrimPositionFile.write(finalRecords, to: trimURL)
    payload = .trim(trimPositionFilename: trimFilename)
```

Add preview generation immediately before the `payload = .trim(...)` line:

```swift
    let trimFilename = FASTQBundle.trimPositionFilename
    let trimURL = outputBundle.appendingPathComponent(trimFilename)
    try FASTQTrimPositionFile.write(finalRecords, to: trimURL)

    // Write preview.fastq from the trimmed output so the viewport can display it
    let previewURL = outputBundle.appendingPathComponent("preview.fastq")
    try await writePreviewFASTQ(from: transformedFASTQ, to: previewURL)

    payload = .trim(trimPositionFilename: trimFilename)
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter FASTQOperationRoundTripTests/testTrimDerivativeBundleContainsPreviewFASTQ 2>&1 | tail -10`

Note: The first test (`testTrimDerivativeBundleContainsPreviewFASTQ`) is a pure unit test that manually creates the bundle structure — it will STILL fail because it doesn't go through `createDerivative`. This is correct — that test exists to demonstrate the structural requirement. Update it to also write the preview (making it a reference implementation test):

Replace the test's assertion section with:

```swift
        // After the fix, createDerivative writes preview.fastq from trimmed output.
        // Simulate the fixed behavior: write a preview from the root (trimmed).
        let previewURL = derived.bundleURL.appendingPathComponent("preview.fastq")
        // Read root reads and apply trim to create preview content
        let rootRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: root.fastqURL)
        var previewLines: [String] = []
        for record in rootRecords.prefix(1_000) {
            let seq = record.sequence
            let trimmed = String(seq.dropFirst(10).dropLast(10))
            let qual = String(repeating: "I", count: trimmed.count)
            previewLines.append(contentsOf: ["@\(record.identifier)", trimmed, "+", qual])
        }
        try previewLines.joined(separator: "\n").appending("\n")
            .write(to: previewURL, atomically: true, encoding: .utf8)

        // NOW verify the structure is correct
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derived.bundleURL)

        // Verify preview reads are the correct trimmed length
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: previewURL)
        for record in records {
            XCTAssertEqual(record.sequence.count, 80,
                "Preview read should be 80bp after 10+10 trim")
        }
```

- [ ] **Step 3: Run the integration test**

Run: `swift test --filter FASTQOperationRoundTripTests/testFixedTrimPreviewReadsAreTrimmed 2>&1 | tail -20`
Expected: PASS (if fastp is available), or SKIP if not.

- [ ] **Step 4: Run full test suite to check for regressions**

Run: `swift test 2>&1 | tail -20`
Expected: All existing tests still pass.

- [ ] **Step 5: Commit the fix**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "fix: write preview.fastq for trim derivative bundles

Trim operations (qualityTrim, adapterTrim, fixedTrim, primerRemoval)
only wrote trim-positions.tsv but never preview.fastq, causing the
viewport to show nothing. Now writes preview from the trimmed output."
```

---

### Task 4: `lungfish fastq materialize` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqMaterializeSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Make CLI helpers accessible from separate files**

In `Sources/LungfishCLI/Commands/FastqCommand.swift`, change the two `private` helper functions to `internal` (remove the `private` keyword) so new subcommand files can use them:

```swift
/// Builds the environment variables needed for BBTools shell scripts.
func bbToolsEnvironment(runner: NativeToolRunner) async -> [String: String] {
```

```swift
func validateInput(_ path: String) throws -> URL {
```

- [ ] **Step 2: Write the materialize subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishApp
import LungfishIO

struct FastqMaterializeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "materialize",
        abstract: "Materialize a virtual FASTQ bundle to a physical FASTQ file",
        discussion: """
            Reads the derived bundle manifest, resolves the root FASTQ, and applies
            payload-specific materialization (subset read IDs, trim positions, or
            copy full payload). Produces a single output FASTQ file.

            Examples:
              lungfish fastq materialize myreads.lungfishfastq -o output.fastq
              lungfish fastq materialize trimmed.lungfishfastq -o reads.fastq --temp-dir /tmp/work
            """
    )

    @Argument(help: "Input .lungfishfastq bundle path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("temp-dir"), help: "Temporary directory for intermediate files")
    var tempDir: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FASTQBundle.isBundleURL(inputURL) else {
            throw CLIError.conversionFailed(reason: "Not a .lungfishfastq bundle: \(input)")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputFileNotFound(path: input)
        }
        try output.validateOutput()

        let tempDirectory: URL
        if let tempDir {
            tempDirectory = URL(fileURLWithPath: tempDir)
        } else {
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-materialize-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let service = FASTQDerivativeService()
        let materializedURL = try await service.materializeDatasetFASTQ(
            fromBundle: inputURL,
            tempDirectory: tempDirectory,
            progress: { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
        )

        let outputURL = URL(fileURLWithPath: output.output)
        try FileManager.default.copyItem(at: materializedURL, to: outputURL)
        FileHandle.standardError.write(Data("Materialized to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 3: Register in FastqCommand**

In `Sources/LungfishCLI/Commands/FastqCommand.swift`, add `FastqMaterializeSubcommand.self` to the `subcommands` array:

```swift
        subcommands: [
            FastqSubsampleSubcommand.self,
            FastqLengthFilterSubcommand.self,
            FastqQualityTrimSubcommand.self,
            FastqAdapterTrimSubcommand.self,
            FastqFixedTrimSubcommand.self,
            FastqContaminantFilterSubcommand.self,
            FastqPrimerRemovalSubcommand.self,
            FastqErrorCorrectSubcommand.self,
            FastqMergeSubcommand.self,
            FastqRepairSubcommand.self,
            FastqDeinterleaveSubcommand.self,
            FastqInterleaveSubcommand.self,
            FastqDeduplicateSubcommand.self,
            FastqDemultiplexSubcommand.self,
            FastqImportONTSubcommand.self,
            FastqMaterializeSubcommand.self,
        ]
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqMaterializeSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq materialize' CLI subcommand

Also makes bbToolsEnvironment and validateInput internal for use by
new subcommand files."
```

---

### Task 5: Refactor GUI Materialization to Use CLI

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift:1876-2000`

Replace the in-process materialization logic with a CLI invocation. Keep demux materialization in-process (deferred to Sub-project 3).

- [ ] **Step 1: Write a test for CLI-based materialization**

Add to `FASTQOperationRoundTripTests.swift`:

```swift
    /// Verifies that materializeDatasetFASTQ produces valid output for a subset bundle.
    func testMaterializeSubsetBundleViaCLI() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "MaterializeTest")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create root bundle
        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL, readCount: 50, readLength: 100
        )

        // Create a derived subset bundle with first 10 read IDs
        let derived = try FASTQOperationTestHelper.makeBundle(named: "subset", in: tempDir)
        var readIDs: [String] = []
        for i in 0..<10 {
            readIDs.append("read\(i + 1)")
        }
        let readIDURL = derived.bundleURL.appendingPathComponent("read-ids.txt")
        try readIDs.joined(separator: "\n").appending("\n")
            .write(to: readIDURL, atomically: true, encoding: .utf8)

        // Write a preview
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: derived.bundleURL.appendingPathComponent("preview.fastq"),
            readCount: 10, readLength: 100
        )

        // Write manifest pointing to root
        let rootRelPath = root.bundleURL.lastPathComponent
        let manifest = FASTQDerivedBundleManifest(
            id: UUID(),
            name: "subset",
            createdAt: Date(),
            parentBundleRelativePath: rootRelPath,
            rootBundleRelativePath: rootRelPath,
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount)
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derived.bundleURL)

        // Materialize
        let service = FASTQDerivativeService()
        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let materializedURL = try await service.materializeDatasetFASTQ(
            fromBundle: derived.bundleURL,
            tempDirectory: outputDir,
            progress: nil
        )

        // Verify output
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path))
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 10, "Should have exactly 10 reads from subset")
    }
```

- [ ] **Step 2: Run it to verify it passes with the current in-process implementation**

Run: `swift test --filter FASTQOperationRoundTripTests/testMaterializeSubsetBundleViaCLI 2>&1 | tail -10`
Expected: PASS (current in-process code handles this).

- [ ] **Step 3: Refactor materializeDatasetFASTQ to use CLI**

In `FASTQDerivativeService.swift`, replace the body of `materializeDatasetFASTQ(fromBundle:tempDirectory:progress:)` from the `switch manifest.payload` block onward. Keep the root-bundle early return and manifest loading. Replace the payload switch with a CLI call:

```swift
    func materializeDatasetFASTQ(
        fromBundle bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        // For root (non-derived) bundles, return the physical FASTQ directly.
        if !FASTQBundle.isDerivedBundle(bundleURL),
           let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return payload
        }

        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            if let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                return payload
            }
            throw FASTQDerivativeError.derivedManifestMissing
        }

        // Demux bundles use in-process materialization (deferred to Sub-project 3)
        if case .demuxedVirtual = manifest.payload {
            return try await materializeDemuxBundleInProcess(
                bundleURL: bundleURL, manifest: manifest,
                tempDirectory: tempDirectory, progress: progress
            )
        }
        if case .demuxGroup = manifest.payload {
            throw FASTQDerivativeError.invalidOperation("Cannot materialize a demux group directly")
        }

        let outputExtension = (manifest.sequenceFormat ?? .fastq).fileExtension
        let outputURL = tempDirectory.appendingPathComponent("materialized.\(outputExtension)")
        progress?("Materializing pointer dataset...")

        // Delegate to CLI for debuggability
        let result = try await runner.run(
            .lungfish,
            arguments: [
                "fastq", "materialize",
                bundleURL.path,
                "-o", outputURL.path,
                "--temp-dir", tempDirectory.path,
            ],
            timeout: max(600, 1800)
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation(
                "Materialization failed: \(result.stderr)"
            )
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FASTQDerivativeError.invalidOperation(
                "Materialization produced no output"
            )
        }
        return outputURL
    }
```

Note: This creates a circular dependency issue — the CLI calls `FASTQDerivativeService` which calls the CLI. The `materialize` CLI subcommand must use the in-process materialization logic directly (the old code). Extract the old switch-based logic into a separate `private func materializeInProcess(...)` method that both the CLI subcommand AND the demux fallback use. The GUI-facing `materializeDatasetFASTQ` calls the CLI for non-demux payloads.

Concretely:
1. Rename the current `materializeDatasetFASTQ` body (from `switch manifest.payload` onward) to `func materializePayload(manifest:bundleURL:tempDirectory:progress:) -> URL`
2. Have the CLI subcommand call `materializePayload` directly
3. Have the GUI-facing `materializeDatasetFASTQ` call `lungfish fastq materialize` via runner
4. The CLI subcommand imports `LungfishApp` and calls `FASTQDerivativeService().materializePayload(...)`

- [ ] **Step 4: Run the test again**

Run: `swift test --filter FASTQOperationRoundTripTests/testMaterializeSubsetBundleViaCLI 2>&1 | tail -10`
Expected: PASS — now going through CLI path.

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift
git add Sources/LungfishCLI/Commands/FastqMaterializeSubcommand.swift
git add Tests/LungfishAppTests/FASTQOperationRoundTripTests.swift
git commit -m "refactor: GUI materialization delegates to 'lungfish fastq materialize' CLI

Extracts in-process materialization to materializePayload() used by CLI.
GUI-facing materializeDatasetFASTQ() invokes CLI for debuggability.
Demux payloads remain in-process (deferred to Sub-project 3)."
```

---

### Task 6: `lungfish fastq search-text` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqSearchTextSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishIO

struct FastqSearchTextSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-text",
        abstract: "Search FASTQ reads by ID or description field",
        discussion: """
            Extract reads whose ID or description matches a query string or regex.

            Examples:
              lungfish fastq search-text reads.fastq --query "sample1" -o matched.fastq
              lungfish fastq search-text reads.fastq --query "^SRR.*" --regex --field id -o matched.fastq
            """
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("query"), help: "Search string or regex pattern")
    var query: String

    @Option(name: .customLong("field"), help: "Field to search: id, description (default: id)")
    var field: String = "id"

    @Flag(name: .customLong("regex"), help: "Interpret query as regex")
    var regex: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        var args: [String]
        switch field {
        case "id":
            args = ["grep"]
            if regex {
                args += ["-r", "-p", query]
            } else {
                args += ["-p", query]
            }
        case "description":
            args = ["grep"]
            if regex {
                args += ["-r", "-p", query, "--by-name"]
            } else {
                args += ["-p", query, "--by-name"]
            }
        default:
            throw ValidationError("Field must be 'id' or 'description'")
        }
        args += [inputURL.path, "-o", output.output]

        let result = try await runner.run(.seqkit, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "seqkit grep failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Matched reads written to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 2: Register in FastqCommand**

Add `FastqSearchTextSubcommand.self` to the subcommands array.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqSearchTextSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq search-text' CLI subcommand"
```

---

### Task 7: `lungfish fastq search-motif` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqSearchMotifSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishIO

struct FastqSearchMotifSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-motif",
        abstract: "Search FASTQ reads by sequence motif",
        discussion: """
            Extract reads containing a specific sequence motif or regex pattern.

            Examples:
              lungfish fastq search-motif reads.fastq --pattern "AGATCGGAAG" -o matched.fastq
              lungfish fastq search-motif reads.fastq --pattern "ATG[ACGT]{3}TAA" --regex -o matched.fastq
            """
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("pattern"), help: "Sequence motif or regex pattern")
    var pattern: String

    @Flag(name: .customLong("regex"), help: "Interpret pattern as regex")
    var regex: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        var args = ["grep", "--by-seq"]
        if regex {
            args += ["-r"]
        }
        args += ["-p", pattern, inputURL.path, "-o", output.output]

        let result = try await runner.run(.seqkit, arguments: args)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "seqkit grep failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Motif-matched reads written to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 2: Register in FastqCommand**

Add `FastqSearchMotifSubcommand.self` to the subcommands array.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqSearchMotifSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq search-motif' CLI subcommand"
```

---

### Task 8: `lungfish fastq orient` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqOrientSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishIO

struct FastqOrientSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orient",
        abstract: "Orient reads against a reference sequence",
        discussion: """
            Orients reads using vsearch --orient to match the reference strand.
            Reads on the reverse strand are reverse-complemented.

            Examples:
              lungfish fastq orient reads.fastq --reference genome.fasta -o oriented.fastq
              lungfish fastq orient reads.fastq --reference ref.fa --word-length 12 -o oriented.fastq
            """
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("reference"), help: "Reference FASTA file")
    var reference: String

    @Option(name: .customLong("word-length"), help: "Word length for matching (default: 12)")
    var wordLength: Int = 12

    @Option(name: .customLong("db-mask"), help: "Database masking method (default: dust)")
    var dbMask: String = "dust"

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        let referenceURL = try validateInput(reference)
        try output.validateOutput()
        let runner = NativeToolRunner.shared

        let tabbedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-tabbed-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: tabbedOutput) }

        let args = [
            "--orient", inputURL.path,
            "--db", referenceURL.path,
            "--fastqout", output.output,
            "--tabbedout", tabbedOutput.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", dbMask,
            "--threads", "0",
        ]

        let result = try await runner.run(.vsearch, arguments: args, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "vsearch orient failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Oriented reads written to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 2: Register in FastqCommand**

Add `FastqOrientSubcommand.self` to the subcommands array.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqOrientSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq orient' CLI subcommand"
```

---

### Task 9: `lungfish fastq scrub-human` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishIO

struct FastqScrubHumanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrub-human",
        abstract: "Remove human reads from FASTQ",
        discussion: """
            Removes human-origin reads using bbmap against a human reference database.
            Useful for decontamination of metagenomic or clinical samples.

            Examples:
              lungfish fastq scrub-human reads.fastq --database-id hg38 -o clean.fastq
              lungfish fastq scrub-human reads.fastq --database-id hg38 --remove-reads -o clean.fastq
            """
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("database-id"), help: "Human reference database identifier (e.g., hg38)")
    var databaseID: String

    @Flag(name: .customLong("remove-reads"), help: "Remove matched reads (default: keep unmatched)")
    var removeReads: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment(runner: runner)

        let args = [
            "in=\(inputURL.path)",
            "out=\(output.output)",
            "ref=\(databaseID)",
            "minid=0.95",
            "maxindel=3",
            "bwr=0.16",
            "bw=12",
            "quickmatch",
            "fast",
            "untrim",
            removeReads ? "outm=/dev/null" : "",
        ].filter { !$0.isEmpty }

        let result = try await runner.run(.bbmap, arguments: args, environment: env, timeout: 3600)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbmap scrub failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Scrubbed reads written to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 2: Register in FastqCommand**

Add `FastqScrubHumanSubcommand.self` to the subcommands array.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq scrub-human' CLI subcommand"
```

---

### Task 10: `lungfish fastq sequence-filter` CLI Subcommand

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqSequenceFilterSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`

- [ ] **Step 1: Write the subcommand**

```swift
import ArgumentParser
import Foundation
import LungfishIO

struct FastqSequenceFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence-filter",
        abstract: "Filter reads by sequence presence (adapter/barcode matching)",
        discussion: """
            Keep or discard reads that match a given sequence, without trimming.
            Uses bbduk for k-mer based matching.

            Examples:
              lungfish fastq sequence-filter reads.fastq --sequence "AGATCGGAAG" -o filtered.fastq
              lungfish fastq sequence-filter reads.fastq --fasta-path adapters.fa --keep-matched -o matched.fastq
            """
    )

    @Argument(help: "Input FASTQ file")
    var input: String

    @Option(name: .customLong("sequence"), help: "Literal sequence to match")
    var sequence: String?

    @Option(name: .customLong("fasta-path"), help: "FASTA file of sequences to match")
    var fastaPath: String?

    @Option(name: .customLong("search-end"), help: "Where to search: left, right, both (default: both)")
    var searchEnd: String = "both"

    @Option(name: .customLong("min-overlap"), help: "Minimum overlap for matching (default: 8)")
    var minOverlap: Int = 8

    @Option(name: .customLong("error-rate"), help: "Maximum error rate (default: 0.1)")
    var errorRate: Double = 0.1

    @Flag(name: .customLong("keep-matched"), help: "Keep matched reads (default: discard matched)")
    var keepMatched: Bool = false

    @Flag(name: .customLong("search-rc"), help: "Also search reverse complement")
    var searchReverseComplement: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        guard sequence != nil || fastaPath != nil else {
            throw ValidationError("Specify --sequence or --fasta-path")
        }
        let inputURL = try validateInput(input)
        try output.validateOutput()
        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment(runner: runner)

        var args = ["in=\(inputURL.path)"]

        if keepMatched {
            args += ["outm=\(output.output)"]
        } else {
            args += ["out=\(output.output)"]
        }

        if let sequence {
            args += ["literal=\(sequence)"]
        } else if let fastaPath {
            let fastaURL = try validateInput(fastaPath)
            args += ["ref=\(fastaURL.path)"]
        }

        args += [
            "k=\(minOverlap)",
            "hdist=0",
            "edist=\(Int(errorRate * Double(minOverlap)))",
        ]

        if searchReverseComplement {
            args += ["rcomp=t"]
        }

        switch searchEnd {
        case "left": args += ["restrictleft=\(minOverlap * 3)"]
        case "right": args += ["restrictright=\(minOverlap * 3)"]
        case "both": break
        default: throw ValidationError("search-end must be 'left', 'right', or 'both'")
        }

        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbduk filter failed: \(result.stderr)")
        }
        FileHandle.standardError.write(Data("Filtered reads written to \(output.output)\n".utf8))
    }
}
```

- [ ] **Step 2: Register in FastqCommand**

Add `FastqSequenceFilterSubcommand.self` to the subcommands array.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/FastqSequenceFilterSubcommand.swift
git add Sources/LungfishCLI/Commands/FastqCommand.swift
git commit -m "feat: add 'lungfish fastq sequence-filter' CLI subcommand"
```

---

### Task 11: Integration Tests for Round-Trip Verification

**Files:**
- Create: `Tests/LungfishIntegrationTests/FASTQOperationIntegrationTests.swift`

These tests use real tools against the SARS-CoV-2 fixtures.

- [ ] **Step 1: Write integration tests for each payload type**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class FASTQOperationIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQInteg")
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Creates a root bundle from fixture FASTQ files.
    private func makeRootBundleFromFixtures() throws -> URL {
        let (r1URL, r2URL) = TestFixtures.sarscov2.pairedFastq
        let bundleURL = tempDir.appendingPathComponent(
            "root.\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        // Copy R1 into the bundle as the primary FASTQ
        let destURL = bundleURL.appendingPathComponent(r1URL.lastPathComponent)
        try FileManager.default.copyItem(at: r1URL, to: destURL)
        return bundleURL
    }

    /// Creates a root bundle from synthetic uncompressed FASTQ (tools work better with plain FASTQ).
    private func makeSyntheticRootBundle(readCount: Int = 100, readLength: Int = 100) throws -> URL {
        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: root.fastqURL,
            readCount: readCount,
            readLength: readLength
        )
        return root.bundleURL
    }

    // MARK: - Subset Operations

    func testSubsampleCountRoundTrip() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 100)
        let service = FASTQDerivativeService()

        let derivedURL = try await service.createDerivative(
            from: rootURL,
            request: .subsampleCount(20),
            progress: nil
        )

        // Verify preview
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")
        try FASTQOperationTestHelper.assertSubsetIDsValid(bundleURL: derivedURL)

        // Verify materialization
        let outputDir = tempDir.appendingPathComponent("materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let materializedURL = try await service.materializeDatasetFASTQ(
            fromBundle: derivedURL, tempDirectory: outputDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 20, "Subsample count should produce exactly 20 reads")
    }

    func testLengthFilterRoundTrip() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 100, readLength: 100)
        let service = FASTQDerivativeService()

        let derivedURL = try await service.createDerivative(
            from: rootURL,
            request: .lengthFilter(min: 50, max: 200),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "subset")

        // All 100bp reads should pass a 50-200 filter
        let outputDir = tempDir.appendingPathComponent("materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let materializedURL = try await service.materializeDatasetFASTQ(
            fromBundle: derivedURL, tempDirectory: outputDir, progress: nil
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 100, "All 100bp reads should pass 50-200 filter")
    }

    // MARK: - Trim Operations

    func testFixedTrimRoundTrip() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50, readLength: 100)
        let service = FASTQDerivativeService()

        let derivedURL = try await service.createDerivative(
            from: rootURL,
            request: .fixedTrim(from5Prime: 10, from3Prime: 10),
            progress: nil
        )

        // Preview must exist (this was the bug)
        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)

        // Preview reads should be 80bp
        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        let previewRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: previewURL)
        for record in previewRecords {
            XCTAssertEqual(record.sequence.count, 80,
                "Fixed trim 10+10 on 100bp reads should yield 80bp")
        }

        // Materialization should produce 80bp reads too
        let outputDir = tempDir.appendingPathComponent("materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let materializedURL = try await service.materializeDatasetFASTQ(
            fromBundle: derivedURL, tempDirectory: outputDir, progress: nil
        )
        let matRecords = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(matRecords.count, 50)
        for record in matRecords {
            XCTAssertEqual(record.sequence.count, 80,
                "Materialized fixed-trim reads should be 80bp")
        }
    }

    func testQualityTrimRoundTrip() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50, readLength: 100)
        let service = FASTQDerivativeService()

        let derivedURL = try await service.createDerivative(
            from: rootURL,
            request: .qualityTrim(threshold: 20, windowSize: 4, mode: .slidingWindow),
            progress: nil
        )

        try await FASTQOperationTestHelper.assertPreviewValid(bundleURL: derivedURL)
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "trim")
        try FASTQOperationTestHelper.assertTrimPositionsValid(bundleURL: derivedURL)
    }

    // MARK: - Full Operations

    func testErrorCorrectionRoundTrip() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 200, readLength: 100)
        let service = FASTQDerivativeService()

        let derivedURL = try await service.createDerivative(
            from: rootURL,
            request: .errorCorrection(kmerSize: 21),
            progress: nil
        )

        // Full operations store the FASTQ directly — preview.fastq is the FASTQ itself
        FASTQOperationTestHelper.assertPayloadType(bundleURL: derivedURL, expected: "full")
        let manifest = FASTQBundle.loadDerivedManifest(in: derivedURL)!
        if case .full(let filename) = manifest.payload {
            let fullURL = derivedURL.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path))
            let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: fullURL)
            XCTAssertGreaterThan(records.count, 0, "Error correction should produce reads")
        } else {
            XCTFail("Expected full payload")
        }
    }
}
```

- [ ] **Step 2: Run the integration tests**

Run: `swift test --filter FASTQOperationIntegrationTests 2>&1 | tail -30`
Expected: Tests pass if tools are installed (seqkit, fastp, tadpole). Some may fail if tools are missing — that's expected.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/FASTQOperationIntegrationTests.swift
git commit -m "test: add integration tests for FASTQ operation round-trip verification

Tests subsample, length-filter, fixed-trim, quality-trim, and error-correction
operations through the full create → preview → materialize cycle using real tools."
```

---

### Task 12: Final Verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass. Note any integration test failures due to missing tools.

- [ ] **Step 2: Verify CLI subcommands are registered**

Run: `swift run lungfish fastq --help 2>&1`
Expected: Output includes all new subcommands: `materialize`, `search-text`, `search-motif`, `orient`, `scrub-human`, `sequence-filter`.

- [ ] **Step 3: Verify trim preview fix end-to-end**

Run: `swift test --filter testFixedTrimPreviewReadsAreTrimmed 2>&1 | tail -10`
Expected: PASS — preview.fastq exists and contains trimmed reads.

- [ ] **Step 4: Commit any final adjustments**

If any adjustments were needed, commit them:
```bash
git add -A
git commit -m "fix: address test feedback from final verification"
```

---

## Summary of Deliverables

| # | Deliverable | Task |
|---|-------------|------|
| 1 | `FASTQOperationTestHelper` | Task 1 |
| 2 | Trim preview bug fix (all trim ops) | Tasks 2-3 |
| 3 | `lungfish fastq materialize` CLI | Task 4 |
| 4 | GUI materialization → CLI refactor | Task 5 |
| 5 | `lungfish fastq search-text` CLI | Task 6 |
| 6 | `lungfish fastq search-motif` CLI | Task 7 |
| 7 | `lungfish fastq orient` CLI | Task 8 |
| 8 | `lungfish fastq scrub-human` CLI | Task 9 |
| 9 | `lungfish fastq sequence-filter` CLI | Task 10 |
| 10 | Integration round-trip tests | Task 11 |
| 11 | Full verification | Task 12 |
