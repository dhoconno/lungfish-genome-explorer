# CLI-Driven FASTQ Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the GUI's direct FASTQBatchImporter call with a CLI subprocess (`lungfish-cli import fastq`), add recursive directory scanning, and a "Sequencing Reads" tab to the Import Center.

**Architecture:** The GUI spawns `lungfish-cli import fastq --format json` via `CLIImportRunner` (new actor), reads structured JSON log events line-by-line, and maps them to `OperationCenter` for real-time progress display. The CLI gains `--recursive` for hierarchical directory scanning with relative-path preservation in output bundles. The Import Center gains a 5th tab for FASTQ files/folders. The config sheet switches from `RecipeRegistry` to `RecipeRegistryV2` and gains a compression picker.

**Tech Stack:** Swift 6.2, Foundation `Process`, ArgumentParser, AppKit (NSViewController), SwiftUI (Import Center), XCTest

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `Sources/LungfishApp/Services/CLIImportRunner.swift` | Actor: spawns `lungfish-cli`, reads JSON event stream, maps to OperationCenter, handles cancellation |
| `Tests/LungfishAppTests/CLIImportRunnerTests.swift` | Unit tests: JSON event parsing, OperationCenter mapping, argument building |
| `Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift` | Unit tests: recursive directory scanning, relative path detection |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` | Add `relativePath` to `SamplePair`, add `detectPairsFromDirectoryRecursive()` |
| `Sources/LungfishCLI/Commands/ImportFastqCommand.swift` | Add `--recursive` flag, use recursive detection for directories when set, emit JSON unconditionally when `--format json` |
| `Sources/LungfishApp/Services/FASTQIngestionService.swift` | Replace `runIngestAndBundle(pair:...)` body with `CLIImportRunner` subprocess |
| `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift` | Add `.sequencingReads` tab, `.fastq` import action, FASTQ card, dispatch logic |
| `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift` | Add 5th tab subtitle |
| `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Switch recipe popup to `RecipeRegistryV2`, add compression picker, rename clumpify checkbox to "Optimize storage" |
| `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift` | Add `compressionLevel` field |
| `Tests/LungfishCLITests/ImportFastqCommandTests.swift` | Add `--recursive` flag parsing test |

---

## Task 1: Add `relativePath` to `SamplePair` and recursive directory scanning

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Test: `Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift`

- [ ] **Step 1: Write failing test for `SamplePair.relativePath`**

Create `Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift`:

```swift
// RecursivePairDetectionTests.swift - Tests for recursive FASTQ pair detection
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class RecursivePairDetectionTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecursivePairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - relativePath on SamplePair

    func testSamplePairRelativePathDefault() {
        let pair = SamplePair(
            sampleName: "Sample1",
            r1: URL(fileURLWithPath: "/data/Sample1_R1.fq.gz"),
            r2: URL(fileURLWithPath: "/data/Sample1_R2.fq.gz")
        )
        XCTAssertNil(pair.relativePath, "Default relativePath should be nil")
    }

    func testSamplePairRelativePathSet() {
        let pair = SamplePair(
            sampleName: "Sample1",
            r1: URL(fileURLWithPath: "/data/plate1/Sample1_R1.fq.gz"),
            r2: URL(fileURLWithPath: "/data/plate1/Sample1_R2.fq.gz"),
            relativePath: "plate1"
        )
        XCTAssertEqual(pair.relativePath, "plate1")
    }

    // MARK: - Recursive detection

    func testDetectPairsFromDirectoryRecursive() throws {
        // Create nested structure:
        // tmpDir/plate1/Sample1_R1.fq.gz, Sample1_R2.fq.gz
        // tmpDir/plate2/Sample2_R1.fq.gz, Sample2_R2.fq.gz
        let plate1 = tmpDir.appendingPathComponent("plate1")
        let plate2 = tmpDir.appendingPathComponent("plate2")
        try FileManager.default.createDirectory(at: plate1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plate2, withIntermediateDirectories: true)

        // Create empty FASTQ files
        FileManager.default.createFile(atPath: plate1.appendingPathComponent("Sample1_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate1.appendingPathComponent("Sample1_R2.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate2.appendingPathComponent("Sample2_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate2.appendingPathComponent("Sample2_R2.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 2)

        let s1 = pairs.first { $0.sampleName == "Sample1" }
        let s2 = pairs.first { $0.sampleName == "Sample2" }
        XCTAssertNotNil(s1)
        XCTAssertNotNil(s2)
        XCTAssertEqual(s1?.relativePath, "plate1")
        XCTAssertEqual(s2?.relativePath, "plate2")
        XCTAssertNotNil(s1?.r2)
        XCTAssertNotNil(s2?.r2)
    }

    func testDetectPairsFromDirectoryRecursiveDeeplyNested() throws {
        // tmpDir/run1/plate1/lane1/Sample_R1.fq.gz, Sample_R2.fq.gz
        let lane = tmpDir.appendingPathComponent("run1/plate1/lane1")
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lane.appendingPathComponent("Deep_R1.fastq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: lane.appendingPathComponent("Deep_R2.fastq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Deep")
        XCTAssertEqual(pairs[0].relativePath, "run1/plate1/lane1")
    }

    func testDetectPairsFromDirectoryRecursiveMixedLevels() throws {
        // Files at root AND in subdirectory
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("Root_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("Root_R2.fq.gz").path, contents: nil)

        let sub = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("Sub_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("Sub_R2.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 2)
        let rootPair = pairs.first { $0.sampleName == "Root" }
        let subPair = pairs.first { $0.sampleName == "Sub" }
        XCTAssertNil(rootPair?.relativePath, "Root-level pair should have nil relativePath")
        XCTAssertEqual(subPair?.relativePath, "subdir")
    }

    func testDetectPairsFromDirectoryRecursiveEmptySubdirs() throws {
        // Empty subdirectories should not cause errors
        let empty = tmpDir.appendingPathComponent("emptydir")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let sub = tmpDir.appendingPathComponent("hasfiles")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("Only_R1.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Only")
        XCTAssertNil(pairs[0].r2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecursivePairDetectionTests 2>&1 | head -30`
Expected: Compilation errors — `SamplePair` has no `relativePath` parameter, `detectPairsFromDirectoryRecursive` does not exist.

- [ ] **Step 3: Add `relativePath` to `SamplePair`**

In `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`, modify the `SamplePair` struct (around line 15):

```swift
public struct SamplePair: Sendable {
    public let sampleName: String
    public let r1: URL
    public let r2: URL?
    public let relativePath: String?  // nil = root of Imports/

    public init(sampleName: String, r1: URL, r2: URL?, relativePath: String? = nil) {
        self.sampleName = sampleName
        self.r1 = r1
        self.r2 = r2
        self.relativePath = relativePath
    }
}
```

- [ ] **Step 4: Implement `detectPairsFromDirectoryRecursive`**

Add this method to the `FASTQBatchImporter` enum, after the existing `detectPairsFromDirectory` method:

```swift
/// Recursively scans a directory tree for FASTQ files, detecting pairs per subdirectory.
///
/// Each returned `SamplePair` includes a `relativePath` indicating the subdirectory
/// relative to `rootDirectory`. Files at the root have `relativePath == nil`.
///
/// - Parameter rootDirectory: The top-level directory to scan.
/// - Returns: All detected pairs sorted by relative path then sample name.
/// - Throws: ``BatchImportError/noFASTQFilesFound(_:)`` if no FASTQ files exist anywhere.
public static func detectPairsFromDirectoryRecursive(_ rootDirectory: URL) throws -> [SamplePair] {
    let fm = FileManager.default
    let fastqExtensions: Set<String> = ["fastq.gz", "fq.gz", "fastq", "fq"]

    // Group FASTQ files by their parent directory
    var filesByDirectory: [URL: [URL]] = [:]

    guard let enumerator = fm.enumerator(
        at: rootDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw BatchImportError.noFASTQFilesFound(rootDirectory)
    }

    for case let fileURL as URL in enumerator {
        let name = fileURL.lastPathComponent.lowercased()
        let isFASTQ = fastqExtensions.contains(where: { name.hasSuffix($0) })
        guard isFASTQ else { continue }
        let parentDir = fileURL.deletingLastPathComponent()
        filesByDirectory[parentDir, default: []].append(fileURL)
    }

    guard !filesByDirectory.isEmpty else {
        throw BatchImportError.noFASTQFilesFound(rootDirectory)
    }

    // Detect pairs per directory and assign relative paths
    let rootPath = rootDirectory.standardizedFileURL.path
    var allPairs: [SamplePair] = []

    for (directory, files) in filesByDirectory {
        let dirPairs = detectPairs(from: files)
        let dirPath = directory.standardizedFileURL.path

        // Compute relative path from root
        let relativePath: String?
        if dirPath == rootPath {
            relativePath = nil
        } else {
            let rel = String(dirPath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            relativePath = rel.isEmpty ? nil : rel
        }

        for pair in dirPairs {
            allPairs.append(SamplePair(
                sampleName: pair.sampleName,
                r1: pair.r1,
                r2: pair.r2,
                relativePath: relativePath
            ))
        }
    }

    return allPairs.sorted { a, b in
        let pathA = a.relativePath ?? ""
        let pathB = b.relativePath ?? ""
        if pathA != pathB { return pathA < pathB }
        return a.sampleName < b.sampleName
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RecursivePairDetectionTests 2>&1 | tail -20`
Expected: All 5 tests PASS.

- [ ] **Step 6: Run existing SamplePair tests to confirm no regression**

Run: `swift test --filter FASTQBatchImporterTests 2>&1 | tail -10`
Expected: All existing tests PASS (the default `relativePath: nil` in the init means no call-site changes needed).

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift
git commit -m "feat: add relativePath to SamplePair and recursive directory scanning"
```

---

## Task 2: Add `--recursive` flag to CLI and JSON event emission for `--format json`

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`
- Test: `Tests/LungfishCLITests/ImportFastqCommandTests.swift`

- [ ] **Step 1: Write failing test for `--recursive` flag parsing**

Append to `Tests/LungfishCLITests/ImportFastqCommandTests.swift`:

```swift
func testParseRecursiveFlag() throws {
    let command = try ImportCommand.FastqSubcommand.parse([
        "/data/sequencing_run/",
        "--project", "/projects/Test.lungfish",
        "--recursive",
    ])
    XCTAssertTrue(command.recursive)
}

func testParseRecursiveDefaultFalse() throws {
    let command = try ImportCommand.FastqSubcommand.parse([
        "/data/fastq_dir",
        "--project", "/projects/Test.lungfish",
    ])
    XCTAssertFalse(command.recursive)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ImportFastqCommandTests/testParseRecursiveFlag 2>&1 | head -20`
Expected: Compilation error — `FastqSubcommand` has no `recursive` property.

- [ ] **Step 3: Add `--recursive` flag to `FastqSubcommand`**

In `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`, add after the `force` flag (around line 96):

```swift
@Flag(
    name: .customLong("recursive"),
    help: "Recursively scan directories for FASTQ files"
)
var recursive: Bool = false
```

- [ ] **Step 4: Use recursive scanning in `run()` when flag is set**

In the `run()` method, replace the directory detection block (around line 122-128). Change:

```swift
if exists && isDirectory.boolValue {
    do {
        pairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
    } catch let batchError as BatchImportError {
```

To:

```swift
if exists && isDirectory.boolValue {
    do {
        if recursive {
            pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(inputURL)
        } else {
            pairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
        }
    } catch let batchError as BatchImportError {
```

- [ ] **Step 5: Emit JSON events unconditionally when `--format json`**

In the `run()` method, change the log callback (around line 265-271). Replace:

```swift
let result = await FASTQBatchImporter.runBatchImport(
    pairs: pairs,
    config: config,
    log: { event in
        let json = FASTQBatchImporter.encodeLogEvent(event)
        print(json)
    }
)
```

With:

```swift
let isJSON = globalOptions.outputFormat == .json
let result = await FASTQBatchImporter.runBatchImport(
    pairs: pairs,
    config: config,
    log: { event in
        if isJSON || !globalOptions.quiet {
            let json = FASTQBatchImporter.encodeLogEvent(event)
            print(json)
        }
    }
)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ImportFastqCommandTests 2>&1 | tail -10`
Expected: All tests PASS (including the two new ones).

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCLI/Commands/ImportFastqCommand.swift Tests/LungfishCLITests/ImportFastqCommandTests.swift
git commit -m "feat: add --recursive flag to CLI fastq import, emit JSON unconditionally for --format json"
```

---

## Task 3: Implement `CLIImportRunner` actor

**Files:**
- Create: `Sources/LungfishApp/Services/CLIImportRunner.swift`
- Test: `Tests/LungfishAppTests/CLIImportRunnerTests.swift`

- [ ] **Step 1: Write failing test for JSON event parsing**

Create `Tests/LungfishAppTests/CLIImportRunnerTests.swift`:

```swift
// CLIImportRunnerTests.swift - Tests for CLIImportRunner JSON event parsing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class CLIImportRunnerTests: XCTestCase {

    func testParseImportStartEvent() throws {
        let json = """
        {"event":"importStart","sampleCount":2,"recipeName":"vsp2","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .importStart(let count, let recipe) = event else {
            XCTFail("Expected importStart, got \(event)")
            return
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(recipe, "vsp2")
    }

    func testParseSampleStartEvent() throws {
        let json = """
        {"event":"sampleStart","sample":"Sample1","index":0,"total":1,"r1":"R1.fq.gz","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .sampleStart(let sample, let index, let total, _, _) = event else {
            XCTFail("Expected sampleStart, got \(event)")
            return
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(total, 1)
    }

    func testParseStepStartEvent() throws {
        let json = """
        {"event":"stepStart","sample":"Sample1","step":"Remove PCR duplicates","stepIndex":1,"totalSteps":5,"timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .stepStart(_, let step, let stepIndex, let totalSteps) = event else {
            XCTFail("Expected stepStart, got \(event)")
            return
        }
        XCTAssertEqual(step, "Remove PCR duplicates")
        XCTAssertEqual(stepIndex, 1)
        XCTAssertEqual(totalSteps, 5)
    }

    func testParseStepCompleteEvent() throws {
        let json = """
        {"event":"stepComplete","sample":"Sample1","step":"Trim adapters","durationSeconds":12.3,"timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .stepComplete(_, let step, let duration) = event else {
            XCTFail("Expected stepComplete, got \(event)")
            return
        }
        XCTAssertEqual(step, "Trim adapters")
        XCTAssertEqual(duration, 12.3, accuracy: 0.01)
    }

    func testParseSampleCompleteEvent() throws {
        let json = """
        {"event":"sampleComplete","sample":"Sample1","bundle":"Sample1.lungfishfastq","durationSeconds":230.5,"originalBytes":4320897082,"finalBytes":1056497969,"timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .sampleComplete(let sample, let bundle, _, let orig, let final_) = event else {
            XCTFail("Expected sampleComplete, got \(event)")
            return
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(bundle, "Sample1.lungfishfastq")
        XCTAssertEqual(orig, 4320897082)
        XCTAssertEqual(final_, 1056497969)
    }

    func testParseSampleFailedEvent() throws {
        let json = """
        {"event":"sampleFailed","sample":"Bad","error":"fastp crashed","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .sampleFailed(let sample, let error) = event else {
            XCTFail("Expected sampleFailed, got \(event)")
            return
        }
        XCTAssertEqual(sample, "Bad")
        XCTAssertEqual(error, "fastp crashed")
    }

    func testParseImportCompleteEvent() throws {
        let json = """
        {"event":"importComplete","completed":1,"skipped":0,"failed":0,"totalDurationSeconds":230.8,"timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .importComplete(let completed, let skipped, let failed, _) = event else {
            XCTFail("Expected importComplete, got \(event)")
            return
        }
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(failed, 0)
    }

    func testParseNonJSONLineReturnsNil() {
        let line = "Starting import..."
        XCTAssertNil(try? CLIImportRunner.parseEvent(from: line))
    }

    func testParseSampleSkipEvent() throws {
        let json = """
        {"event":"sampleSkip","sample":"Already","reason":"bundle exists","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try CLIImportRunner.parseEvent(from: json)
        guard case .sampleSkip(let sample, let reason) = event else {
            XCTFail("Expected sampleSkip, got \(event)")
            return
        }
        XCTAssertEqual(sample, "Already")
        XCTAssertEqual(reason, "bundle exists")
    }

    // MARK: - Argument Building

    func testBuildCLIArgumentsPairedEnd() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/S1_R1.fq.gz"),
            r2: URL(fileURLWithPath: "/data/S1_R2.fq.gz"),
            projectDirectory: URL(fileURLWithPath: "/projects/Test.lungfish"),
            platform: "illumina",
            recipeName: "vsp2",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced"
        )
        XCTAssertTrue(args.contains("import"))
        XCTAssertTrue(args.contains("fastq"))
        XCTAssertTrue(args.contains("/data/S1_R1.fq.gz"))
        XCTAssertTrue(args.contains("/data/S1_R2.fq.gz"))
        XCTAssertTrue(args.contains("--project"))
        XCTAssertTrue(args.contains("--recipe"))
        XCTAssertTrue(args.contains("vsp2"))
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
        XCTAssertFalse(args.contains("--no-optimize-storage"))
    }

    func testBuildCLIArgumentsSingleEndNoRecipe() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/projects/Test.lungfish"),
            platform: "ont",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast"
        )
        XCTAssertFalse(args.contains("/data/S1_R2.fq.gz"))
        XCTAssertFalse(args.contains("--recipe"))
        XCTAssertTrue(args.contains("--no-optimize-storage"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("fast"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CLIImportRunnerTests 2>&1 | head -20`
Expected: Compilation error — `CLIImportRunner` does not exist.

- [ ] **Step 3: Implement `CLIImportRunner`**

Create `Sources/LungfishApp/Services/CLIImportRunner.swift`:

```swift
// CLIImportRunner.swift - Spawns lungfish-cli and reads JSON events
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.app, category: "CLIImportRunner")

/// Parsed JSON events from the CLI's structured output.
///
/// Mirrors `ImportLogEvent` from LungfishWorkflow, but decoded from JSON
/// rather than constructed in-process. Using a separate type avoids a
/// module dependency from LungfishApp on the internal event format.
enum CLIImportEvent: Sendable {
    case importStart(sampleCount: Int, recipeName: String?)
    case sampleStart(sample: String, index: Int, total: Int, r1: String, r2: String?)
    case stepStart(sample: String, step: String, stepIndex: Int, totalSteps: Int)
    case stepComplete(sample: String, step: String, durationSeconds: Double)
    case sampleComplete(sample: String, bundle: String, durationSeconds: Double, originalBytes: Int64, finalBytes: Int64)
    case sampleSkip(sample: String, reason: String)
    case sampleFailed(sample: String, error: String)
    case importComplete(completed: Int, skipped: Int, failed: Int, totalDurationSeconds: Double)
}

/// Spawns `lungfish-cli import fastq` as a subprocess and reads its
/// structured JSON log events for real-time OperationCenter updates.
actor CLIImportRunner {

    private var process: Process?

    // MARK: - Binary Resolution

    /// Resolves the `lungfish-cli` binary path.
    ///
    /// Search order:
    /// 1. `<AppBundle>/Contents/MacOS/lungfish-cli` (release)
    /// 2. `.build/debug/lungfish-cli` (development)
    /// 3. PATH lookup via `/usr/bin/which`
    static func cliBinaryPath() -> URL? {
        // 1. App bundle
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("lungfish-cli"),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }

        // 2. Development build
        let devPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/lungfish-cli")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        // 3. PATH lookup
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["lungfish-cli"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            // Fall through
        }

        return nil
    }

    // MARK: - Argument Building

    /// Builds the CLI argument array from GUI import parameters.
    static func buildCLIArguments(
        r1: URL,
        r2: URL?,
        projectDirectory: URL,
        platform: String,
        recipeName: String?,
        qualityBinning: String,
        optimizeStorage: Bool,
        compressionLevel: String
    ) -> [String] {
        var args = ["import", "fastq"]
        args.append(r1.path)
        if let r2 { args.append(r2.path) }
        args += ["--project", projectDirectory.path]
        args += ["--platform", platform]
        if let recipe = recipeName {
            args += ["--recipe", recipe]
        }
        args += ["--quality-binning", qualityBinning]
        if !optimizeStorage {
            args.append("--no-optimize-storage")
        }
        args += ["--compression", compressionLevel]
        args += ["--format", "json"]
        args.append("--force")
        return args
    }

    // MARK: - Event Parsing

    /// Parses a single JSON line into a ``CLIImportEvent``.
    ///
    /// Returns `nil` for non-JSON lines (e.g. human-readable progress text).
    /// Throws for valid JSON that doesn't match the expected event schema.
    static func parseEvent(from line: String) throws -> CLIImportEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = dict["event"] as? String else {
            return nil
        }

        switch eventType {
        case "importStart":
            return .importStart(
                sampleCount: dict["sampleCount"] as? Int ?? 0,
                recipeName: dict["recipeName"] as? String
            )
        case "sampleStart":
            return .sampleStart(
                sample: dict["sample"] as? String ?? "",
                index: dict["index"] as? Int ?? 0,
                total: dict["total"] as? Int ?? 0,
                r1: dict["r1"] as? String ?? "",
                r2: dict["r2"] as? String
            )
        case "stepStart":
            return .stepStart(
                sample: dict["sample"] as? String ?? "",
                step: dict["step"] as? String ?? "",
                stepIndex: dict["stepIndex"] as? Int ?? 0,
                totalSteps: dict["totalSteps"] as? Int ?? 0
            )
        case "stepComplete":
            return .stepComplete(
                sample: dict["sample"] as? String ?? "",
                step: dict["step"] as? String ?? "",
                durationSeconds: dict["durationSeconds"] as? Double ?? 0
            )
        case "sampleComplete":
            return .sampleComplete(
                sample: dict["sample"] as? String ?? "",
                bundle: dict["bundle"] as? String ?? "",
                durationSeconds: dict["durationSeconds"] as? Double ?? 0,
                originalBytes: (dict["originalBytes"] as? NSNumber)?.int64Value ?? 0,
                finalBytes: (dict["finalBytes"] as? NSNumber)?.int64Value ?? 0
            )
        case "sampleSkip":
            return .sampleSkip(
                sample: dict["sample"] as? String ?? "",
                reason: dict["reason"] as? String ?? ""
            )
        case "sampleFailed":
            return .sampleFailed(
                sample: dict["sample"] as? String ?? "",
                error: dict["error"] as? String ?? ""
            )
        case "importComplete":
            return .importComplete(
                completed: dict["completed"] as? Int ?? 0,
                skipped: dict["skipped"] as? Int ?? 0,
                failed: dict["failed"] as? Int ?? 0,
                totalDurationSeconds: dict["totalDurationSeconds"] as? Double ?? 0
            )
        default:
            logger.debug("Unknown CLI event type: \(eventType)")
            return nil
        }
    }

    // MARK: - Run

    /// Spawns `lungfish-cli import fastq` with the given arguments and maps
    /// JSON log events to `OperationCenter` for real-time progress display.
    ///
    /// - Parameters:
    ///   - arguments: CLI arguments (excluding the binary path).
    ///   - operationID: The OperationCenter item ID to update.
    ///   - projectDirectory: Project directory (used to resolve bundle URLs).
    ///   - onBundleCreated: Called when a sample bundle is created successfully.
    ///   - onError: Called if a sample fails or the process exits with error.
    func run(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        onBundleCreated: @Sendable (URL) -> Void,
        onError: @Sendable (Error) -> Void
    ) async {
        guard let binaryURL = Self.cliBinaryPath() else {
            let err = NSError(
                domain: "CLIImportRunner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "lungfish-cli binary not found"]
            )
            logger.error("CLI binary not found")
            onError(err)
            return
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.process = proc

        do {
            try proc.run()
        } catch {
            logger.error("Failed to launch CLI: \(error)")
            onError(error)
            return
        }

        logger.info("Spawned lungfish-cli (pid \(proc.processIdentifier)) with args: \(arguments.joined(separator: " "))")

        // Read stdout line by line
        let handle = stdoutPipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        proc.waitUntilExit()

        let exitCode = proc.terminationStatus
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

        // Parse events
        let lines = output.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            guard let event = try? Self.parseEvent(from: line) else {
                logger.debug("Non-JSON CLI output: \(line)")
                continue
            }

            switch event {
            case .sampleStart(let sample, _, _, _, _):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: operationID,
                            progress: 0.05,
                            detail: "Importing \(sample)\u{2026}"
                        )
                    }
                }

            case .stepStart(let sample, let step, let stepIndex, let totalSteps):
                let fraction = Double(stepIndex) / Double(max(1, totalSteps + 1))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: operationID,
                            progress: fraction * 0.80,
                            detail: "\(sample): \(step)"
                        )
                        OperationCenter.shared.log(
                            id: operationID,
                            level: .info,
                            message: step
                        )
                    }
                }

            case .stepComplete(_, let step, let duration):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: operationID,
                            level: .info,
                            message: "\(step) completed (\(String(format: "%.1f", duration))s)"
                        )
                    }
                }

            case .sampleComplete(_, let bundle, _, _, _):
                let bundleURL = projectDirectory
                    .appendingPathComponent("Imports")
                    .appendingPathComponent(bundle)
                onBundleCreated(bundleURL)

            case .sampleFailed(let sample, let error):
                logger.error("Sample \(sample) failed: \(error)")
                onError(NSError(
                    domain: "CLIImportRunner", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(sample): \(error)"]
                ))

            case .importComplete(let completed, let skipped, let failed, _):
                let detail = "\(completed) imported, \(skipped) skipped, \(failed) failed"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: operationID,
                            level: .info,
                            message: detail
                        )
                    }
                }

            case .sampleSkip(let sample, let reason):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: operationID,
                            level: .info,
                            message: "Skipped \(sample): \(reason)"
                        )
                    }
                }

            default:
                break
            }
        }

        // Handle non-zero exit
        if exitCode != 0 {
            let errMsg = stderrOutput.isEmpty
                ? "CLI exited with code \(exitCode)"
                : stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("CLI failed (exit \(exitCode)): \(errMsg)")
            onError(NSError(
                domain: "CLIImportRunner", code: Int(exitCode),
                userInfo: [NSLocalizedDescriptionKey: errMsg]
            ))
        }

        self.process = nil
    }

    // MARK: - Cancellation

    /// Sends SIGTERM to the child process.
    func cancel() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        logger.info("Sent SIGTERM to CLI process (pid \(proc.processIdentifier))")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CLIImportRunnerTests 2>&1 | tail -20`
Expected: All 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/CLIImportRunner.swift Tests/LungfishAppTests/CLIImportRunnerTests.swift
git commit -m "feat: add CLIImportRunner actor for CLI subprocess management"
```

---

## Task 4: Wire `FASTQIngestionService` to use `CLIImportRunner`

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift`

- [ ] **Step 1: Replace `runIngestAndBundle(pair:...)` to use CLIImportRunner**

In `Sources/LungfishApp/Services/FASTQIngestionService.swift`, replace the `runIngestAndBundle(pair:projectDirectory:bundleName:importConfig:operationID:completion:)` method (around line 343-578) with:

```swift
/// Ingests using CLIImportRunner (subprocess approach).
///
/// Spawns `lungfish-cli import fastq --format json` and reads structured
/// events for OperationCenter progress. After the CLI creates the bundle,
/// computes FASTQ statistics and records provenance.
nonisolated private static func runIngestAndBundle(
    pair: FASTQFilePair,
    projectDirectory: URL,
    bundleName: String,
    importConfig: FASTQImportConfiguration,
    operationID opID: UUID,
    completion: @escaping @MainActor (Result<URL, Error>) -> Void
) async {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            OperationCenter.shared.update(
                id: opID,
                progress: 0,
                detail: "Waiting for available import slot\u{2026}"
            )
        }
    }
    await FASTQImportSlotCoordinator.shared.acquire()
    defer {
        Task { await FASTQImportSlotCoordinator.shared.release() }
    }

    // Map GUI platform enum to CLI string
    let platformStr: String
    switch importConfig.confirmedPlatform {
    case .illumina:       platformStr = "illumina"
    case .oxfordNanopore: platformStr = "ont"
    case .pacbio:         platformStr = "pacbio"
    case .ultima:         platformStr = "ultima"
    default:              platformStr = "illumina"
    }

    // Resolve recipe name
    let recipeName: String? = {
        guard let recipe = importConfig.postImportRecipe, !recipe.steps.isEmpty else { return nil }
        // Check for new-format VSP2 recipe
        if recipe.name.lowercased().contains("vsp2") {
            if let nr = RecipeRegistryV2.allRecipes().first(where: { $0.name.lowercased().contains("vsp2") }) {
                return nr.id
            }
        }
        return recipe.name.lowercased()
    }()

    // Resolve compression level string
    let compressionStr: String = {
        if let level = importConfig.compressionLevel {
            return level.rawValue
        }
        return "balanced"
    }()

    let args = CLIImportRunner.buildCLIArguments(
        r1: pair.r1,
        r2: pair.r2,
        projectDirectory: projectDirectory,
        platform: platformStr,
        recipeName: recipeName,
        qualityBinning: importConfig.qualityBinning.rawValue,
        optimizeStorage: !importConfig.skipClumpify,
        compressionLevel: compressionStr
    )

    // Update the OperationCenter with the actual CLI command
    let cliCmd = "lungfish-cli " + args.joined(separator: " ")
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            OperationCenter.shared.items.first(where: { $0.id == opID })?.cliCommand = cliCmd
        }
    }

    let runner = CLIImportRunner()
    var bundleCreated: URL? = nil
    var importError: Error? = nil

    await runner.run(
        arguments: args,
        operationID: opID,
        projectDirectory: projectDirectory,
        onBundleCreated: { url in
            bundleCreated = url
        },
        onError: { error in
            importError = error
        }
    )

    // Handle failure
    if let error = importError, bundleCreated == nil {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                completion(.failure(error))
            }
        }
        return
    }

    guard let bundleURL = bundleCreated else {
        let msg = "Import produced no output"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OperationCenter.shared.fail(id: opID, detail: msg)
                completion(.failure(NSError(
                    domain: "FASTQIngestionService", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )))
            }
        }
        return
    }

    // Post-processing: compute FASTQ statistics
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            OperationCenter.shared.update(
                id: opID,
                progress: 0.85,
                detail: "Computing FASTQ statistics\u{2026}"
            )
        }
    }

    let fm = FileManager.default
    let bundleContents = (try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)) ?? []
    let primaryFASTQ = bundleContents.first(where: {
        let name = $0.lastPathComponent.lowercased()
        return name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz") ||
               name.hasSuffix(".fastq") || name.hasSuffix(".fq")
    })

    if let fastqURL = primaryFASTQ {
        let existingMetadata = FASTQMetadataStore.load(for: fastqURL)
        _ = try? await FASTQStatisticsService.computeAndCache(
            for: fastqURL,
            existingMetadata: existingMetadata,
            progress: { count in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: opID,
                            progress: 0.90,
                            detail: "Computing FASTQ statistics\u{2026} \(count) reads processed"
                        )
                    }
                }
            }
        )
    }

    // Record provenance
    var parameters: [String: ParameterValue] = [
        "platform": .string(platformStr),
        "pairingMode": .string(importConfig.pairingMode.rawValue),
        "qualityBinning": .string(importConfig.qualityBinning.rawValue),
        "skipClumpify": .boolean(importConfig.skipClumpify),
    ]
    if let recipeName {
        parameters["recipe"] = .string(recipeName)
    }
    let runID = await ProvenanceRecorder.shared.beginRun(
        name: "FASTQ Import: \(bundleName)",
        parameters: parameters
    )
    await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
    try? await ProvenanceRecorder.shared.save(runID: runID, to: bundleURL)

    // Complete
    let detail = "Imported \(bundleURL.lastPathComponent)"
    logger.info("ingestAndBundle: Created bundle \(bundleURL.lastPathComponent) via CLI subprocess")

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: [bundleURL])
            completion(.success(bundleURL))
        }
    }
}
```

- [ ] **Step 2: Update the CLI command string in `ingestAndBundle(pair:...)` public method**

In the `ingestAndBundle(pair:projectDirectory:bundleName:importConfig:completion:)` method (around line 279-283), change the `cliCmd` construction from:

```swift
let cliCmd: String = {
    var args = [pair.r1.path]
    if let r2 = pair.r2 { args.append(r2.path) }
    return "# lungfish import fastq " + args.joined(separator: " ") + " (CLI command not yet available \u{2014} use GUI)"
}()
```

To:

```swift
let cliCmd: String = {
    var args = ["lungfish-cli", "import", "fastq", pair.r1.path]
    if let r2 = pair.r2 { args.append(r2.path) }
    args += ["--project", projectDirectory.path, "--format", "json"]
    return args.joined(separator: " ")
}()
```

- [ ] **Step 3: Add `import LungfishWorkflow` if not already present**

Check the imports at the top of `FASTQIngestionService.swift`. It already has `import LungfishWorkflow` (line 5). Confirm `RecipeRegistryV2` is accessible — it's a public enum in LungfishWorkflow, so no additional imports needed.

- [ ] **Step 4: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Build succeeds. (If `FASTQImportConfiguration.compressionLevel` doesn't exist yet, that will be added in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQIngestionService.swift
git commit -m "feat: wire FASTQIngestionService to CLIImportRunner subprocess"
```

---

## Task 5: Add "Sequencing Reads" tab to Import Center

**Files:**
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`

- [ ] **Step 1: Add `.sequencingReads` tab to the `Tab` enum**

In `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`, modify the `Tab` enum (around line 101) to add `sequencingReads` as the FIRST case so it's the leftmost tab:

```swift
enum Tab: Int, CaseIterable, Hashable, Sendable {
    case sequencingReads
    case alignments
    case variants
    case classificationResults
    case references

    var title: String {
        switch self {
        case .sequencingReads:       return "Sequencing Reads"
        case .alignments:            return "Alignments"
        case .variants:              return "Variants"
        case .classificationResults: return "Classification"
        case .references:            return "References"
        }
    }

    var sfSymbol: String {
        switch self {
        case .sequencingReads:       return "waveform.path"
        case .alignments:            return "arrow.left.arrow.right"
        case .variants:              return "diamond.fill"
        case .classificationResults: return "chart.bar.doc.horizontal"
        case .references:            return "doc.text"
        }
    }

    var segmentIndex: Int { rawValue }

    static func from(segmentIndex: Int) -> Tab {
        Tab(rawValue: segmentIndex) ?? .classificationResults
    }
}
```

- [ ] **Step 2: Add `.fastq` to `ImportAction` enum**

In the `ImportAction` enum (around line 66), add:

```swift
enum ImportAction: Sendable {
    case fastq
    case bam
    case vcf
    case fasta
    case naoMgs
    case kraken2
    case esViritu
    case taxTriage
    case nvd
}
```

- [ ] **Step 3: Add FASTQ card to `allCards`**

Add the FASTQ card as the FIRST entry in `allCards` (before BAM/CRAM):

```swift
// Sequencing Reads
ImportCardInfo(
    id: "fastq",
    title: "FASTQ Files",
    description: "Import paired-end or single-end sequencing reads. Supports individual files and folders with automatic pair detection.",
    sfSymbol: "waveform.path",
    fileHint: ".fastq.gz, .fq.gz, .fastq, .fq (files or folders)",
    tab: .sequencingReads,
    importKind: .filePanel(
        allowedTypes: [
            UTType(filenameExtension: "gz") ?? .data,
            UTType(filenameExtension: "fastq") ?? .data,
            UTType(filenameExtension: "fq") ?? .data,
            .folder,
        ],
        action: .fastq
    )
),
```

- [ ] **Step 4: Update `openFilePanel` to allow directories for FASTQ**

In `openFilePanel(allowedTypes:action:)` (around line 374), change the `canChooseDirectories` line:

```swift
panel.canChooseDirectories = (action == .fastq || action == .esViritu || action == .taxTriage || action == .nvd)
```

- [ ] **Step 5: Add panel message for FASTQ**

In `panelMessage(for:)` (around line 385), add at the top of the switch:

```swift
case .fastq: return "Select FASTQ files or folders to import"
```

- [ ] **Step 6: Add FASTQ dispatch in `dispatchFileImport`**

In `dispatchFileImport(urls:action:)` (around line 410), add before the `.bam` case:

```swift
case .fastq:
    appDelegate.importFASTQFromURLs(urls)
```

- [ ] **Step 7: Add FASTQ history label**

In `historyLabel(for:)` (around line 476), add:

```swift
case .fastq: return "FASTQ"
```

- [ ] **Step 8: Update default selected tab**

Change `selectedTab` initial value (around line 139) to default to the new first tab:

```swift
var selectedTab: Tab = .sequencingReads
```

- [ ] **Step 9: Add tab subtitle in ImportCenterView**

In `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`, in `tabSubtitle` (around line 78), add:

```swift
case .sequencingReads:
    return "Import raw sequencing data for processing and analysis"
```

- [ ] **Step 10: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Build succeeds. (The `appDelegate.importFASTQFromURLs` method may not exist yet — if so, add a stub in AppDelegate or use a `// TODO` and handle in a later task. For now, the critical thing is the Import Center structure.)

Note: If `importFASTQFromURLs` doesn't exist on AppDelegate, add a minimal stub:

```swift
// In AppDelegate, add:
@objc func importFASTQFromURLs(_ urls: [URL]) {
    // Will be connected to FASTQImportConfigSheet in a later step
    logger.info("FASTQ import requested for \(urls.count) URL(s)")
}
```

- [ ] **Step 11: Commit**

```bash
git add Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift
git commit -m "feat: add Sequencing Reads tab with FASTQ card to Import Center"
```

---

## Task 6: Update `FASTQImportConfigSheet` — RecipeRegistryV2, compression picker, rename clumpify

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift`

- [ ] **Step 1: Add `compressionLevel` to `FASTQImportConfiguration`**

In `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift`, add the field to the struct:

```swift
public struct FASTQImportConfiguration: Sendable {
    public let inputFiles: [URL]
    public let detectedPlatform: LungfishIO.SequencingPlatform
    public let confirmedPlatform: LungfishIO.SequencingPlatform
    public let pairingMode: FASTQIngestionConfig.PairingMode
    public let qualityBinning: QualityBinningScheme
    public let skipClumpify: Bool
    public let deleteOriginals: Bool
    public let postImportRecipe: ProcessingRecipe?
    public let resolvedPlaceholders: [String: String]
    public let compressionLevel: CompressionLevel?
}
```

Update all call sites that construct `FASTQImportConfiguration` to include `compressionLevel:`. The existing call in `FASTQIngestionService.swift` (line 315) should add `compressionLevel: nil` and the main construction in `FASTQImportConfigSheet`'s `importClicked` will set it from the new picker.

- [ ] **Step 2: Switch recipe popup from `RecipeRegistry` to `RecipeRegistryV2`**

In `FASTQImportConfigSheet.swift`, change the recipe loading (around line 169):

From:
```swift
allRecipes = RecipeRegistry.loadAllRecipes()
for recipe in allRecipes {
    recipePopup.addItem(withTitle: recipe.name)
}
```

Replace the `allRecipes` property type. Change the stored property (around line 31):

From:
```swift
private var allRecipes: [ProcessingRecipe] = []
```
To:
```swift
private var allV2Recipes: [Recipe] = []
```

Then update the recipe popup setup:

```swift
allV2Recipes = RecipeRegistryV2.allRecipes()
for recipe in allV2Recipes {
    recipePopup.addItem(withTitle: recipe.name)
}
```

Also update `recipeChanged` action to reference `allV2Recipes` for descriptions.

- [ ] **Step 3: Add compression level picker**

Add a new property for the compression popup:

```swift
private let compressionLabel = NSTextField(labelWithString: "Compression:")
private let compressionPopup = NSPopUpButton()
```

In `setupUI()`, after the clumpify checkbox section, add:

```swift
// Compression level
compressionLabel.font = .systemFont(ofSize: 12, weight: .medium)
compressionLabel.alignment = .right
compressionLabel.translatesAutoresizingMaskIntoConstraints = false
compressionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
view.addSubview(compressionLabel)

compressionPopup.addItems(withTitles: ["Fast", "Balanced", "Maximum"])
compressionPopup.selectItem(at: 1) // Default: Balanced
compressionPopup.font = .systemFont(ofSize: 12)
compressionPopup.translatesAutoresizingMaskIntoConstraints = false
view.addSubview(compressionPopup)
```

Add constraints for the compression row after the clumpify checkbox constraints:

```swift
compressionLabel.topAnchor.constraint(equalTo: clumpifyCheckbox.bottomAnchor, constant: 10),
compressionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
compressionLabel.widthAnchor.constraint(equalToConstant: labelWidth),
compressionPopup.centerYAnchor.constraint(equalTo: compressionLabel.centerYAnchor),
compressionPopup.leadingAnchor.constraint(equalTo: compressionLabel.trailingAnchor, constant: 8),
```

Update `sep2` to anchor below compressionLabel instead of clumpifyCheckbox:

```swift
sep2.topAnchor.constraint(equalTo: compressionLabel.bottomAnchor, constant: 12),
```

- [ ] **Step 4: Rename "Clumpify" checkbox to "Optimize storage"**

Change the clumpify checkbox initialization (around line 148):

From:
```swift
private let clumpifyCheckbox = NSButton(checkboxWithTitle: "Clumpify (k-mer sort for compression)", target: nil, action: nil)
```
To:
```swift
private let clumpifyCheckbox = NSButton(checkboxWithTitle: "Optimize storage (reorder reads for better compression)", target: nil, action: nil)
```

- [ ] **Step 5: Update `importClicked` to include compression level in config**

In the `importClicked` action method, read the compression popup and pass it to the configuration:

```swift
let compressionLevel: CompressionLevel = {
    switch compressionPopup.indexOfSelectedItem {
    case 0:  return .fast
    case 2:  return .maximum
    default: return .balanced
    }
}()
```

Include `compressionLevel: compressionLevel` in the `FASTQImportConfiguration` construction.

- [ ] **Step 6: Increase sheet height to accommodate new row**

Change the container frame height (around line 71):

From:
```swift
let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
```
To:
```swift
let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
```

- [ ] **Step 7: Delete the dead `RecipeRegistry` enum (old, in LungfishIO)**

The old `RecipeRegistry` enum in `Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift` (around line 446) has zero callers after the config sheet change. Delete the entire `public enum RecipeRegistry { ... }` block from that file. Do NOT delete `ProcessingRecipe` — it's still used by the batch importer for legacy recipes.

Also delete its test file: `Tests/LungfishWorkflowTests/Recipes/RecipeRegistryTests.swift`.

- [ ] **Step 8: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift Tests/LungfishWorkflowTests/Recipes/RecipeRegistryTests.swift
git commit -m "feat: update config sheet — RecipeRegistryV2, compression picker, rename clumpify

Remove dead RecipeRegistry enum (old, LungfishIO) — zero callers remain."
```

---

## Task 7: Wire `FASTQIngestionService.runIngestAndBundle` to use `compressionLevel` from config

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift`

- [ ] **Step 1: Update the legacy `runIngestAndBundle(sourceURL:...)` call to include `compressionLevel`**

In the legacy wrapper (around line 315), add `compressionLevel: nil` to the `FASTQImportConfiguration` construction:

```swift
let importConfig = FASTQImportConfiguration(
    inputFiles: [sourceURL],
    detectedPlatform: .unknown,
    confirmedPlatform: .unknown,
    pairingMode: .singleEnd,
    qualityBinning: .illumina4,
    skipClumpify: false,
    deleteOriginals: false,
    postImportRecipe: nil,
    resolvedPlaceholders: [:],
    compressionLevel: nil
)
```

- [ ] **Step 2: Build to confirm all call sites compile**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 3: Run full test suite to check for regressions**

Run: `swift test 2>&1 | tail -30`
Expected: All tests PASS. No regressions from the `compressionLevel` addition.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQIngestionService.swift
git commit -m "fix: include compressionLevel in all FASTQImportConfiguration call sites"
```

---

## Task 8: Use `relativePath` in bundle output path

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`

- [ ] **Step 1: Write failing test for relative path in bundle output**

Add to `Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift`:

```swift
func testBundleOutputPathWithRelativePath() {
    let pair = SamplePair(
        sampleName: "Sample1",
        r1: URL(fileURLWithPath: "/data/plate1/Sample1_R1.fq.gz"),
        r2: nil,
        relativePath: "plate1"
    )

    let projectDir = URL(fileURLWithPath: "/projects/Test.lungfish")
    let expected = projectDir
        .appendingPathComponent("Imports")
        .appendingPathComponent("plate1")
        .appendingPathComponent("Sample1.lungfishfastq")

    let actual = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDir)
    XCTAssertEqual(actual, expected)
}

func testBundleOutputPathWithoutRelativePath() {
    let pair = SamplePair(
        sampleName: "Sample1",
        r1: URL(fileURLWithPath: "/data/Sample1_R1.fq.gz"),
        r2: nil
    )

    let projectDir = URL(fileURLWithPath: "/projects/Test.lungfish")
    let expected = projectDir
        .appendingPathComponent("Imports")
        .appendingPathComponent("Sample1.lungfishfastq")

    let actual = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDir)
    XCTAssertEqual(actual, expected)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecursivePairDetectionTests/testBundleOutputPath 2>&1 | head -20`
Expected: Compilation error — `bundleOutputURL` does not exist.

- [ ] **Step 3: Add `bundleOutputURL` helper and use it in bundle creation**

In `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`, add a public static method:

```swift
/// Computes the output bundle URL, incorporating `relativePath` for
/// recursive directory imports.
///
/// - Standard: `<project>/Imports/<sampleName>.lungfishfastq`
/// - Recursive: `<project>/Imports/<relativePath>/<sampleName>.lungfishfastq`
public static func bundleOutputURL(for pair: SamplePair, in projectDirectory: URL) -> URL {
    var importsDir = projectDirectory.appendingPathComponent("Imports")
    if let rel = pair.relativePath {
        importsDir = importsDir.appendingPathComponent(rel)
    }
    return importsDir.appendingPathComponent("\(pair.sampleName).lungfishfastq")
}
```

Then update the existing bundle creation code in `runBatchImport` (find where it creates the `Imports/<sampleName>.lungfishfastq` directory) to use this helper instead of hardcoding the path. The exact line will be inside the per-sample processing loop — search for `appendingPathComponent("Imports")` within the method.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecursivePairDetectionTests 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/RecursivePairDetectionTests.swift
git commit -m "feat: use relativePath in bundle output directory for recursive imports"
```

---

## Task 9: Full build and regression test

**Files:** None (verification only)

- [ ] **Step 1: Full build**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run entire test suite**

Run: `swift test 2>&1 | tail -40`
Expected: All tests PASS. Note any failures and fix before continuing.

- [ ] **Step 3: Run new tests specifically**

Run: `swift test --filter "RecursivePairDetectionTests|CLIImportRunnerTests|ImportFastqCommandTests" 2>&1 | tail -20`
Expected: All new tests PASS.

- [ ] **Step 4: Commit any fixups if needed**

```bash
# Only if fixes were needed:
git add -A && git commit -m "fix: address test regressions from CLI-driven import changes"
```
