# FASTQ Batch Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a memory-safe `lungfish import fastq` CLI command that processes paired-end FASTQ samples sequentially with aggressive intermediate cleanup, then wire the GUI drag-and-drop to spawn this command as a child process.

**Architecture:** New `FASTQBatchImporter` in LungfishWorkflow handles the core logic (pair detection, sequential recipe execution with intermediate cleanup, structured logging). `ImportFastqCommand` in LungfishCLI exposes it via ArgumentParser. `FASTQIngestionService` gets a new code path that spawns the CLI as a subprocess instead of running the pipeline inline. Memory safety comes from: autoreleasepool per sample, intermediate file deletion between recipe steps, bounded stderr capture, and reduced Java heap (60% vs 80%).

**Tech Stack:** Swift 6.2, ArgumentParser, Foundation Process, os.log, LungfishIO (ProcessingRecipe, FASTQBundle), LungfishWorkflow (NativeToolRunner, FASTQIngestionPipeline)

---

## File Map

### New Files

| File | Responsibility |
|------|----------------|
| `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` | Core batch import logic: pair detection, sequential sample processing, intermediate cleanup, structured logging, autoreleasepool boundaries |
| `Sources/LungfishCLI/Commands/ImportFastqCommand.swift` | ArgumentParser command wrapping FASTQBatchImporter |
| `Tests/LungfishCLITests/ImportFastqCommandTests.swift` | Unit tests: argument parsing, pair detection, recipe resolution, dry-run |
| `Tests/LungfishIntegrationTests/FASTQBatchImportTests.swift` | Integration tests: full pipeline, intermediate cleanup, bundle structure, logging |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/LungfishCLI/Commands/ImportCommand.swift:51-60` | Add `FastqSubcommand.self` to subcommands array |
| `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:315-316` | Reduce Java heap from 80% to 60% |
| `Sources/LungfishWorkflow/Native/NativeToolRunner.swift:499-518` | Add bounded stderr capture (64KB tail) |
| `Sources/LungfishApp/Services/FASTQIngestionService.swift:833-974` | Add intermediate cleanup in `runVSP2RecipeWithDelayedInterleave`; add CLI subprocess spawn path |

---

## Task 1: Bounded Stderr Capture in NativeToolRunner

Memory safety fix: limit stderr buffering to last 64KB instead of unbounded `readDataToEndOfFile()`.

**Files:**
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift:73-75,499-518`
- Test: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift` (add test)

- [ ] **Step 1: Write failing test for bounded stderr**

Create a test that verifies large stderr output is truncated. Add to `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`:

```swift
func testBoundedStderrCapture() async throws {
    // Generate >64KB of stderr output using a shell command
    let runner = NativeToolRunner.shared
    let result = try await runner.runProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", "for i in $(seq 1 5000); do echo \"stderr line $i with padding to make it longer than typical\" >&2; done"],
        timeout: 30,
        toolName: "test-bounded-stderr",
        maxStderrBytes: 65_536
    )
    // 5000 lines × ~60 bytes = ~300KB stderr; should be truncated to ~64KB
    XCTAssertLessThanOrEqual(result.stderr.utf8.count, 70_000, "stderr should be bounded to ~64KB")
    XCTAssertTrue(result.stderr.contains("stderr line 5000"), "should contain the last lines")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NativeToolRunnerTests/testBoundedStderrCapture 2>&1 | tail -5`
Expected: FAIL — `runProcess` doesn't accept `maxStderrBytes` parameter yet.

- [ ] **Step 3: Add TailBuffer helper class and maxStderrBytes parameter**

In `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, add `TailBuffer` below the existing `DataBox` class (after line 75):

```swift
/// Ring buffer that retains only the last `capacity` bytes of appended data.
/// Used to bound stderr capture for long-running tools like BBTools.
private final class TailBuffer: @unchecked Sendable {
    private let capacity: Int
    private var buffer: Data

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Data()
        self.buffer.reserveCapacity(capacity)
    }

    func append(_ chunk: Data) {
        buffer.append(chunk)
        if buffer.count > capacity {
            buffer = buffer.suffix(capacity)
        }
    }

    var data: Data { buffer }
}
```

Then modify `runProcess` to accept an optional `maxStderrBytes` parameter. Change the signature (line 449):

```swift
public func runProcess(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil,
    toolName: String? = nil,
    maxStderrBytes: Int? = nil
) async throws -> NativeToolResult {
```

In the pipe-draining section (replacing lines 507-510), change the stderr drain to use TailBuffer when `maxStderrBytes` is set:

```swift
drainGroup.enter()
DispatchQueue.global().async {
    if let maxBytes = maxStderrBytes {
        let tailBuf = TailBuffer(capacity: maxBytes)
        let handle = stderrPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            tailBuf.append(chunk)
        }
        stderrBox.value = tailBuf.data
    } else {
        stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }
    drainGroup.leave()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NativeToolRunnerTests/testBoundedStderrCapture 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Native/NativeToolRunner.swift Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift
git commit -m "feat: add bounded stderr capture to NativeToolRunner

Adds TailBuffer ring buffer and maxStderrBytes parameter to runProcess.
Prevents unbounded memory growth when tools like BBTools clumpify write
hundreds of MB of progress lines to stderr."
```

---

## Task 2: Reduce Java Heap Cap (80% → 60%)

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:315-316`
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift:843`

- [ ] **Step 1: Change heap calculation in FASTQIngestionPipeline**

In `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`, change lines 313-316:

Old:
```swift
// Allocate ~80% of physical memory to Java heap, capped at 31g (JVM compressed oops limit).
// Minimum 4g to handle large FASTQ files (BBTools default is only 2g).
let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
let heapGB = max(4, min(31, physicalMemoryGB * 80 / 100))
```

New:
```swift
// Allocate ~60% of physical memory to Java heap, capped at 31g (JVM compressed oops limit).
// Minimum 4g to handle large FASTQ files (BBTools default is only 2g).
// 60% leaves headroom for the OS, file cache, and the import process itself.
let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))
```

- [ ] **Step 2: Change heap calculation in FASTQIngestionService.runVSP2RecipeWithDelayedInterleave**

In `Sources/LungfishApp/Services/FASTQIngestionService.swift`, change line 843:

Old:
```swift
let heapGB = max(4, min(31, physicalMemoryGB * 80 / 100))
```

New:
```swift
let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))
```

- [ ] **Step 3: Run existing tests to verify no regressions**

Run: `swift test --filter FASTQIngestion 2>&1 | tail -10`
Expected: All existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift Sources/LungfishApp/Services/FASTQIngestionService.swift
git commit -m "fix: reduce Java heap cap from 80% to 60% of physical memory

Leaves more headroom for the OS, file cache, and the import process
itself. Prevents macOS jetsam during large batch imports where BBTools
clumpify runs repeatedly."
```

---

## Task 3: Intermediate File Cleanup in VSP2 Delayed Interleave

Fix the root cause of disk/memory exhaustion during multi-step recipe processing.

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift:845-974`

- [ ] **Step 1: Add intermediate cleanup between recipe steps**

In `Sources/LungfishApp/Services/FASTQIngestionService.swift`, in the `runVSP2RecipeWithDelayedInterleave` method, add cleanup logic. Replace lines 845-846 and the loop body around lines 960-974.

After the existing line `var currentR1 = r1` / `var currentR2 = r2` (lines 845-846), add tracking variables:

```swift
var currentR1 = r1
var currentR2 = r2
var prefixStepResults: [RecipeStepResult] = []
var consumedSteps = 0
// Track intermediate files for cleanup (don't delete the original inputs)
var previousR1: URL? = nil
var previousR2: URL? = nil
```

Then at lines 972-974 where `currentR1` and `currentR2` are reassigned, add cleanup:

Old:
```swift
currentR1 = outR1
currentR2 = outR2
consumedSteps += 1
```

New:
```swift
// Delete previous step's intermediate files (not the original inputs)
if let prev1 = previousR1 { try? fm.removeItem(at: prev1) }
if let prev2 = previousR2 { try? fm.removeItem(at: prev2) }
logger.info("VSP2 step \(consumedSteps + 1) complete; cleaned up previous intermediates")

previousR1 = outR1
previousR2 = outR2
currentR1 = outR1
currentR2 = outR2
consumedSteps += 1
```

Also need to declare `let fm = FileManager.default` at the top of the method (after line 840), if not already present.

- [ ] **Step 2: Run existing tests to verify no regressions**

Run: `swift test 2>&1 | grep -E "(Test Suite|failed|passed)" | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQIngestionService.swift
git commit -m "fix: clean up intermediate files between VSP2 recipe steps

Each VSP2 delayed-interleave step creates uncompressed R1/R2 files
(10-50 GB each). Previously these accumulated until workspace cleanup.
Now each step deletes the previous step's files, keeping only the
current output pair on disk at any time."
```

---

## Task 4: FASTQBatchImporter Core — Pair Detection and Recipe Resolution

The shared core logic used by both CLI and GUI.

**Files:**
- Create: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`

- [ ] **Step 1: Write failing tests for pair detection and recipe resolution**

Create `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`:

```swift
// FASTQBatchImporterTests.swift
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class FASTQBatchImporterTests: XCTestCase {

    // MARK: - Pair Detection

    func testPairDetectionIlluminaStandard() throws {
        let files = [
            URL(fileURLWithPath: "/data/Sample1_S1_L008_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/Sample1_S1_L008_R2_001.fastq.gz"),
            URL(fileURLWithPath: "/data/Sample2_S2_L008_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/Sample2_S2_L008_R2_001.fastq.gz"),
        ]
        let pairs = FASTQBatchImporter.detectPairs(from: files)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].sampleName, "Sample1_S1_L008")
        XCTAssertTrue(pairs[0].r1.lastPathComponent.contains("R1"))
        XCTAssertNotNil(pairs[0].r2)
    }

    func testPairDetectionUnpairedFile() throws {
        let files = [
            URL(fileURLWithPath: "/data/orphan.fastq.gz"),
        ]
        let pairs = FASTQBatchImporter.detectPairs(from: files)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertNil(pairs[0].r2)
    }

    func testPairDetectionFromDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create empty files
        for name in ["A_R1_001.fastq.gz", "A_R2_001.fastq.gz", "B_R1_001.fastq.gz", "B_R2_001.fastq.gz"] {
            FileManager.default.createFile(atPath: tempDir.appendingPathComponent(name).path, contents: nil)
        }

        let pairs = try FASTQBatchImporter.detectPairsFromDirectory(tempDir)
        XCTAssertEqual(pairs.count, 2)
    }

    // MARK: - Recipe Resolution

    func testRecipeResolutionVSP2() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "vsp2")
        XCTAssertEqual(recipe.name, "Illumina VSP2 Target Enrichment")
        XCTAssertEqual(recipe.steps.count, 6)
    }

    func testRecipeResolutionWGS() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "wgs")
        XCTAssertEqual(recipe.name, "Illumina WGS")
    }

    func testRecipeResolutionNone() throws {
        let recipe = try? FASTQBatchImporter.resolveRecipe(named: "none")
        XCTAssertNil(recipe)
    }

    func testRecipeResolutionUnknown() throws {
        XCTAssertThrowsError(try FASTQBatchImporter.resolveRecipe(named: "nonexistent"))
    }

    // MARK: - Skip-If-Exists

    func testSkipExistingBundles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake existing bundle
        let bundleDir = tempDir.appendingPathComponent("SampleA.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let pair = SamplePair(
            sampleName: "SampleA",
            r1: URL(fileURLWithPath: "/data/A_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/A_R2.fastq.gz")
        )

        XCTAssertTrue(FASTQBatchImporter.bundleExists(for: pair, in: tempDir))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FASTQBatchImporterTests 2>&1 | tail -5`
Expected: FAIL — `FASTQBatchImporter` doesn't exist yet.

- [ ] **Step 3: Implement FASTQBatchImporter with pair detection and recipe resolution**

Create `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`:

```swift
// FASTQBatchImporter.swift - Memory-safe batch FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQBatchImporter")

// MARK: - Types

/// A detected paired-end sample ready for import.
public struct SamplePair: Sendable {
    public let sampleName: String
    public let r1: URL
    public let r2: URL?

    public init(sampleName: String, r1: URL, r2: URL?) {
        self.sampleName = sampleName
        self.r1 = r1
        self.r2 = r2
    }
}

/// Structured log event emitted during batch import.
public enum ImportLogEvent: Sendable {
    case importStart(sampleCount: Int, recipeName: String?)
    case sampleStart(sample: String, index: Int, total: Int, r1: String, r2: String?)
    case stepStart(sample: String, step: String, stepIndex: Int, totalSteps: Int)
    case stepComplete(sample: String, step: String, durationSeconds: Double)
    case sampleComplete(sample: String, bundle: String, durationSeconds: Double, originalBytes: Int64, finalBytes: Int64)
    case sampleSkip(sample: String, reason: String)
    case sampleFailed(sample: String, error: String)
    case importComplete(completed: Int, skipped: Int, failed: Int, totalDurationSeconds: Double)
}

public enum BatchImportError: Error, LocalizedError {
    case noFASTQFilesFound(URL)
    case unknownRecipe(String)
    case projectNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .noFASTQFilesFound(let url):
            return "No .fastq.gz files found in \(url.path)"
        case .unknownRecipe(let name):
            return "Unknown recipe: \(name). Available: vsp2, wgs, amplicon, hifi"
        case .projectNotFound(let url):
            return "Project directory not found: \(url.path)"
        }
    }
}

// MARK: - FASTQBatchImporter

/// Memory-safe batch FASTQ importer.
///
/// Processes paired-end FASTQ samples **sequentially** (one at a time) with:
/// - Intermediate file cleanup between recipe steps
/// - `autoreleasepool` boundaries between samples
/// - Bounded stderr capture for external tools
/// - Structured JSON logging for progress monitoring
public enum FASTQBatchImporter {

    // MARK: - Pair Detection

    /// Scans a directory for `.fastq.gz` files and groups them into R1/R2 pairs.
    public static func detectPairsFromDirectory(_ directory: URL) throws -> [SamplePair] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let fastqFiles = contents.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz")
        }
        guard !fastqFiles.isEmpty else {
            throw BatchImportError.noFASTQFilesFound(directory)
        }
        return detectPairs(from: fastqFiles)
    }

    /// Groups FASTQ file URLs into R1/R2 pairs using Illumina naming conventions.
    public static func detectPairs(from urls: [URL]) -> [SamplePair] {
        let suffixPairs: [(r1: String, r2: String)] = [
            ("_R1_001", "_R2_001"),
            ("_R1", "_R2"),
            ("_1", "_2"),
        ]

        func stem(of url: URL) -> String {
            var name = url.lastPathComponent
            if name.hasSuffix(".gz") { name = String(name.dropLast(3)) }
            if name.hasSuffix(".fastq") { name = String(name.dropLast(6)) }
            else if name.hasSuffix(".fq") { name = String(name.dropLast(3)) }
            return name
        }

        func sampleName(from stemStr: String) -> String {
            for (r1Suffix, _) in suffixPairs {
                if stemStr.hasSuffix(r1Suffix) {
                    return String(stemStr.dropLast(r1Suffix.count))
                }
            }
            for (_, r2Suffix) in suffixPairs {
                if stemStr.hasSuffix(r2Suffix) {
                    return String(stemStr.dropLast(r2Suffix.count))
                }
            }
            return stemStr
        }

        var matched = Set<URL>()
        var pairs: [SamplePair] = []
        let stemMap = Dictionary(grouping: urls, by: { stem(of: $0) })

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !matched.contains(url) else { continue }
            let s = stem(of: url)

            var foundPair = false
            for (r1Suffix, r2Suffix) in suffixPairs {
                if s.hasSuffix(r1Suffix) {
                    let r2Stem = String(s.dropLast(r1Suffix.count)) + r2Suffix
                    if let r2Candidates = stemMap[r2Stem],
                       let r2 = r2Candidates.first,
                       !matched.contains(r2) {
                        pairs.append(SamplePair(
                            sampleName: sampleName(from: s),
                            r1: url,
                            r2: r2
                        ))
                        matched.insert(url)
                        matched.insert(r2)
                        foundPair = true
                        break
                    }
                }
            }

            if !foundPair {
                pairs.append(SamplePair(
                    sampleName: sampleName(from: s),
                    r1: url,
                    r2: nil
                ))
                matched.insert(url)
            }
        }

        return pairs
    }

    // MARK: - Recipe Resolution

    /// Resolves a recipe name string to a built-in ProcessingRecipe.
    ///
    /// - Parameter named: One of "vsp2", "wgs", "amplicon", "hifi".
    /// - Returns: The resolved ProcessingRecipe.
    /// - Throws: `BatchImportError.unknownRecipe` for unrecognized names.
    ///           Returns nil for "none".
    public static func resolveRecipe(named: String) throws -> ProcessingRecipe {
        switch named.lowercased() {
        case "vsp2":
            return ProcessingRecipe.illuminaVSP2TargetEnrichment
        case "wgs":
            return ProcessingRecipe.illuminaWGS
        case "amplicon":
            return ProcessingRecipe.targetedAmplicon
        case "hifi":
            return ProcessingRecipe.pacbioHiFi
        default:
            throw BatchImportError.unknownRecipe(named)
        }
    }

    // MARK: - Skip-If-Exists

    /// Checks if a `.lungfishfastq` bundle already exists for a sample in the project.
    public static func bundleExists(for pair: SamplePair, in projectDir: URL) -> Bool {
        let bundlePath = projectDir.appendingPathComponent(
            "\(pair.sampleName).\(FASTQBundle.directoryExtension)"
        )
        return FASTQBundle.isBundleURL(bundlePath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FASTQBatchImporterTests 2>&1 | tail -10`
Expected: All 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift
git commit -m "feat: add FASTQBatchImporter with pair detection and recipe resolution

Core logic for the new CLI import command. Detects R1/R2 pairs from
directory listings using Illumina naming conventions, resolves built-in
recipe names, and checks for existing bundles to support resumability."
```

---

## Task 5: FASTQBatchImporter — Structured Logging

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift` (add tests)

- [ ] **Step 1: Write failing test for JSON log encoding**

Add to `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`:

```swift
// MARK: - Structured Logging

func testLogEventJSONEncoding() throws {
    let event = ImportLogEvent.sampleComplete(
        sample: "TestSample",
        bundle: "TestSample.lungfishfastq",
        durationSeconds: 123.4,
        originalBytes: 5_000_000_000,
        finalBytes: 1_000_000_000
    )
    let json = FASTQBatchImporter.encodeLogEvent(event)
    XCTAssertTrue(json.contains("\"event\":\"sample_complete\""))
    XCTAssertTrue(json.contains("\"sample\":\"TestSample\""))
    XCTAssertTrue(json.contains("\"duration_s\":123.4"))
}

func testLogEventImportStart() throws {
    let event = ImportLogEvent.importStart(sampleCount: 52, recipeName: "Illumina VSP2 Target Enrichment")
    let json = FASTQBatchImporter.encodeLogEvent(event)
    XCTAssertTrue(json.contains("\"event\":\"import_start\""))
    XCTAssertTrue(json.contains("\"sample_count\":52"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FASTQBatchImporterTests/testLogEvent 2>&1 | tail -5`
Expected: FAIL — `encodeLogEvent` doesn't exist.

- [ ] **Step 3: Implement encodeLogEvent**

Add to `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`, inside the `FASTQBatchImporter` enum:

```swift
// MARK: - Structured Logging

/// Encodes a log event as a single JSON line for machine consumption.
public static func encodeLogEvent(_ event: ImportLogEvent) -> String {
    var dict: [String: Any] = [:]
    dict["timestamp"] = ISO8601DateFormatter().string(from: Date())

    switch event {
    case .importStart(let count, let recipe):
        dict["event"] = "import_start"
        dict["sample_count"] = count
        dict["recipe"] = recipe as Any
    case .sampleStart(let sample, let index, let total, let r1, let r2):
        dict["event"] = "sample_start"
        dict["sample"] = sample
        dict["index"] = index
        dict["total"] = total
        dict["r1"] = r1
        dict["r2"] = r2 as Any
    case .stepStart(let sample, let step, let stepIndex, let totalSteps):
        dict["event"] = "step_start"
        dict["sample"] = sample
        dict["step"] = step
        dict["step_index"] = stepIndex
        dict["total_steps"] = totalSteps
    case .stepComplete(let sample, let step, let duration):
        dict["event"] = "step_complete"
        dict["sample"] = sample
        dict["step"] = step
        dict["duration_s"] = duration
    case .sampleComplete(let sample, let bundle, let duration, let origBytes, let finalBytes):
        dict["event"] = "sample_complete"
        dict["sample"] = sample
        dict["bundle"] = bundle
        dict["duration_s"] = duration
        dict["original_bytes"] = origBytes
        dict["final_bytes"] = finalBytes
    case .sampleSkip(let sample, let reason):
        dict["event"] = "sample_skip"
        dict["sample"] = sample
        dict["reason"] = reason
    case .sampleFailed(let sample, let error):
        dict["event"] = "sample_failed"
        dict["sample"] = sample
        dict["error"] = error
    case .importComplete(let completed, let skipped, let failed, let duration):
        dict["event"] = "import_complete"
        dict["completed"] = completed
        dict["skipped"] = skipped
        dict["failed"] = failed
        dict["total_duration_s"] = duration
    }

    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        return "{\"event\":\"encoding_error\"}"
    }
    return str
}

/// Writes a human-readable progress line to stderr.
public static func printProgress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter FASTQBatchImporterTests/testLogEvent 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift
git commit -m "feat: add structured JSON logging to FASTQBatchImporter

Machine-readable JSON lines on stdout for GUI progress parsing.
Human-readable progress on stderr for terminal display."
```

---

## Task 6: FASTQBatchImporter — Sequential Sample Processing with Memory Safety

The main processing loop with autoreleasepool, intermediate cleanup, and all memory safety measures.

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Test: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift` (add test)

- [ ] **Step 1: Write failing test for single sample import**

Add to `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`:

```swift
// MARK: - Import Config

func testImportConfigConstruction() throws {
    let pair = SamplePair(
        sampleName: "TestSample",
        r1: URL(fileURLWithPath: "/data/Test_R1_001.fastq.gz"),
        r2: URL(fileURLWithPath: "/data/Test_R2_001.fastq.gz")
    )
    let config = FASTQBatchImporter.ImportConfig(
        projectDirectory: URL(fileURLWithPath: "/project/Test.lungfish"),
        recipe: try FASTQBatchImporter.resolveRecipe(named: "vsp2"),
        qualityBinning: .illumina4,
        threads: 8,
        logDirectory: nil
    )
    XCTAssertEqual(config.recipe?.name, "Illumina VSP2 Target Enrichment")
    XCTAssertEqual(config.threads, 8)
    XCTAssertEqual(config.qualityBinning, .illumina4)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FASTQBatchImporterTests/testImportConfig 2>&1 | tail -5`
Expected: FAIL — `ImportConfig` doesn't exist.

- [ ] **Step 3: Implement ImportConfig and the main runBatchImport method**

Add to `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`, inside the enum:

```swift
// MARK: - Import Configuration

/// Configuration for a batch import run.
public struct ImportConfig: Sendable {
    public let projectDirectory: URL
    public let recipe: ProcessingRecipe?
    public let qualityBinning: QualityBinningScheme
    public let threads: Int
    public let logDirectory: URL?

    public init(
        projectDirectory: URL,
        recipe: ProcessingRecipe?,
        qualityBinning: QualityBinningScheme = .illumina4,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        logDirectory: URL? = nil
    ) {
        self.projectDirectory = projectDirectory
        self.recipe = recipe
        self.qualityBinning = qualityBinning
        self.threads = threads
        self.logDirectory = logDirectory
    }
}

/// Result of a batch import run.
public struct ImportResult: Sendable {
    public let completed: Int
    public let skipped: Int
    public let failed: Int
    public let totalDurationSeconds: Double
    public let errors: [(sample: String, error: String)]
}

// MARK: - Main Entry Point

/// Runs a batch import of FASTQ samples sequentially with memory safety.
///
/// Each sample is processed fully (recipe → clumpify → bundle → stats) before
/// the next starts. Memory is drained between samples via `autoreleasepool`.
///
/// - Parameters:
///   - pairs: Detected sample pairs to import.
///   - config: Import configuration.
///   - log: Callback for structured log events (written to stdout by CLI).
/// - Returns: Summary of completed/skipped/failed samples.
public static func runBatchImport(
    pairs: [SamplePair],
    config: ImportConfig,
    log: @escaping @Sendable (ImportLogEvent) -> Void
) async -> ImportResult {
    let startTime = Date()
    var completed = 0
    var skipped = 0
    var failed = 0
    var errors: [(sample: String, error: String)] = []

    log(.importStart(sampleCount: pairs.count, recipeName: config.recipe?.name))

    for (index, pair) in pairs.enumerated() {
        // Skip if bundle already exists
        if bundleExists(for: pair, in: config.projectDirectory) {
            log(.sampleSkip(sample: pair.sampleName, reason: "bundle already exists"))
            skipped += 1
            continue
        }

        log(.sampleStart(
            sample: pair.sampleName,
            index: index + 1,
            total: pairs.count,
            r1: pair.r1.lastPathComponent,
            r2: pair.r2?.lastPathComponent
        ))
        printProgress("[\(index + 1)/\(pairs.count)] \(pair.sampleName)")

        let sampleStart = Date()

        // autoreleasepool drains Foundation bridging objects between samples
        let result: Result<URL, Error> = await autoreleasepool {
            await processSingleSample(
                pair: pair,
                config: config,
                sampleIndex: index,
                totalSamples: pairs.count,
                log: log
            )
        }

        let sampleDuration = Date().timeIntervalSince(sampleStart)

        switch result {
        case .success(let bundleURL):
            let originalBytes = fileSizeSum([pair.r1] + (pair.r2.map { [$0] } ?? []))
            let finalBytes = bundleFileSize(bundleURL)
            log(.sampleComplete(
                sample: pair.sampleName,
                bundle: bundleURL.lastPathComponent,
                durationSeconds: sampleDuration,
                originalBytes: originalBytes,
                finalBytes: finalBytes
            ))
            let savedPct = originalBytes > 0 ? Int((1.0 - Double(finalBytes) / Double(originalBytes)) * 100) : 0
            let savedStr = ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)
            let finalStr = ByteCountFormatter.string(fromByteCount: finalBytes, countStyle: .file)
            printProgress("  \u{2713} Created \(bundleURL.lastPathComponent) (\(savedStr) \u{2192} \(finalStr), saved \(savedPct)%)")
            completed += 1

        case .failure(let error):
            log(.sampleFailed(sample: pair.sampleName, error: error.localizedDescription))
            printProgress("  \u{2717} FAILED: \(error.localizedDescription)")
            errors.append((pair.sampleName, error.localizedDescription))
            failed += 1
        }
    }

    let totalDuration = Date().timeIntervalSince(startTime)
    log(.importComplete(completed: completed, skipped: skipped, failed: failed, totalDurationSeconds: totalDuration))
    printProgress("\nImport complete: \(completed) completed, \(skipped) skipped, \(failed) failed (\(Int(totalDuration))s)")

    return ImportResult(
        completed: completed,
        skipped: skipped,
        failed: failed,
        totalDurationSeconds: totalDuration,
        errors: errors
    )
}

// MARK: - Single Sample Processing

private static func processSingleSample(
    pair: SamplePair,
    config: ImportConfig,
    sampleIndex: Int,
    totalSamples: Int,
    log: @escaping @Sendable (ImportLogEvent) -> Void
) async -> Result<URL, Error> {
    let fm = FileManager.default
    var workspace: URL?

    do {
        // 1. Create workspace on same volume as source
        workspace = try createIngestionWorkspace(anchoredAt: pair.r1)

        // 2. Run recipe if configured
        var processedFASTQ: URL
        var recipeStepResults: [RecipeStepResult] = []

        if let recipe = config.recipe, !recipe.steps.isEmpty {
            let recipeResult = try await runRecipeWithCleanup(
                pair: pair,
                recipe: recipe,
                workspace: workspace!,
                threads: config.threads,
                log: log
            )
            processedFASTQ = recipeResult.url
            recipeStepResults = recipeResult.stepResults
        } else {
            // No recipe — just use the raw input
            processedFASTQ = pair.r1
        }

        // 3. Clumpify + compress
        log(.stepStart(sample: pair.sampleName, step: "clumpify", stepIndex: (config.recipe?.steps.count ?? 0) + 1, totalSteps: (config.recipe?.steps.count ?? 0) + 1))
        printProgress("  \u{2192} Clumpify + compress...")
        let clumpifyStart = Date()

        let pairingMode: FASTQIngestionConfig.PairingMode = pair.r2 != nil ? .interleaved : .singleEnd
        let clumpifyConfig = FASTQIngestionConfig(
            inputFiles: [processedFASTQ],
            pairingMode: pairingMode,
            outputDirectory: workspace!,
            threads: config.threads,
            deleteOriginals: true,
            qualityBinning: config.qualityBinning,
            skipClumpify: false
        )
        let clumpified = try await FASTQIngestionPipeline().run(config: clumpifyConfig) { _, _ in }

        log(.stepComplete(sample: pair.sampleName, step: "clumpify", durationSeconds: Date().timeIntervalSince(clumpifyStart)))
        printProgress("  \u{2192} Clumpify + compress... done (\(Int(Date().timeIntervalSince(clumpifyStart)))s)")

        // 4. Create .lungfishfastq bundle
        let bundleURL = config.projectDirectory.appendingPathComponent(
            "\(pair.sampleName).\(FASTQBundle.directoryExtension)"
        )
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let destFASTQ = bundleURL.appendingPathComponent(clumpified.outputFile.lastPathComponent)
        try fm.moveItem(at: clumpified.outputFile, to: destFASTQ)

        // 5. Write metadata
        let pairingMeta: IngestionMetadata.PairingMode = pair.r2 != nil ? .interleaved : .singleEnd
        let ingestion = IngestionMetadata(
            isClumpified: clumpified.wasClumpified,
            isCompressed: true,
            pairingMode: pairingMeta,
            qualityBinning: clumpified.qualityBinning.rawValue,
            originalFilenames: [pair.r1.lastPathComponent] + (pair.r2.map { [$0.lastPathComponent] } ?? []),
            ingestionDate: Date(),
            originalSizeBytes: clumpified.originalSizeBytes
        )
        var metadata = PersistedFASTQMetadata()
        metadata.ingestion = ingestion
        if let recipe = config.recipe, !recipeStepResults.isEmpty {
            metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                recipeID: recipe.id.uuidString,
                recipeName: recipe.name,
                appliedDate: Date(),
                stepResults: recipeStepResults
            )
        }
        FASTQMetadataStore.save(metadata, for: destFASTQ)

        // 6. Compute statistics
        printProgress("  \u{2192} Computing statistics...")
        _ = try await FASTQStatisticsService.computeAndCache(for: destFASTQ, existingMetadata: metadata)

        // 7. Write per-sample log
        if let logDir = config.logDirectory {
            try? writePerSampleLog(pair: pair, bundleURL: bundleURL, logDir: logDir)
        }

        // 8. Cleanup workspace
        if let ws = workspace {
            try? fm.removeItem(at: ws)
        }

        return .success(bundleURL)

    } catch {
        // Cleanup on failure
        if let ws = workspace {
            try? fm.removeItem(at: ws)
        }
        return .failure(error)
    }
}

// MARK: - Recipe Execution with Intermediate Cleanup

private static func runRecipeWithCleanup(
    pair: SamplePair,
    recipe: ProcessingRecipe,
    workspace: URL,
    threads: Int,
    log: @escaping @Sendable (ImportLogEvent) -> Void
) async throws -> (url: URL, stepResults: [RecipeStepResult]) {
    let fm = FileManager.default
    let runner = NativeToolRunner.shared
    let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    let heapGB = max(4, min(31, physicalMemoryGB * 60 / 100))

    // Start with R1/R2 as separate files; interleave when needed
    var currentR1 = pair.r1
    var currentR2 = pair.r2
    var previousR1: URL? = nil
    var previousR2: URL? = nil
    var stepResults: [RecipeStepResult] = []
    var consumedPairedSteps = 0

    // Process paired-prefix steps (deduplicate, adapterTrim, qualityTrim) on split files
    for (stepIndex, step) in recipe.steps.enumerated() {
        guard step.kind == .deduplicate || step.kind == .adapterTrim || step.kind == .qualityTrim else {
            break
        }
        guard let r2 = currentR2 else { break }

        let stepStart = Date()
        log(.stepStart(sample: pair.sampleName, step: step.kind.rawValue, stepIndex: stepIndex + 1, totalSteps: recipe.steps.count))
        printProgress("  \u{2192} \(step.displaySummary)...")

        let outR1 = workspace.appendingPathComponent("step_\(stepIndex + 1)_R1.fastq")
        let outR2 = workspace.appendingPathComponent("step_\(stepIndex + 1)_R2.fastq")

        let env = await bbToolsEnvironment()

        switch step.kind {
        case .deduplicate:
            var args = [
                "in1=\(currentR1.path)", "in2=\(r2.path)",
                "out1=\(outR1.path)", "out2=\(outR2.path)",
                "-Xmx\(heapGB)g", "dedupe=t",
                "subs=\(step.deduplicateSubstitutions ?? 0)", "ow=t",
            ]
            if step.deduplicateOptical == true {
                args += ["optical=t", "dupedist=\(step.deduplicateOpticalDistance ?? 2500)"]
            }
            let result = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
            guard result.isSuccess else { throw FASTQIngestionError.clumpifyFailed("paired dedup failed: \(String(result.stderr.suffix(500)))") }

        case .adapterTrim:
            var args = [
                "-i", currentR1.path, "-I", r2.path,
                "-o", outR1.path, "-O", outR2.path,
                "-w", String(threads),
                "--disable_quality_filtering", "--disable_length_filtering",
                "--json", "/dev/null", "--html", "/dev/null",
            ]
            if let seq = step.adapterSequence { args += ["--adapter_sequence", seq] }
            if let seqR2 = step.adapterSequenceR2 { args += ["--adapter_sequence_r2", seqR2] }
            let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
            guard result.isSuccess else { throw FASTQIngestionError.clumpifyFailed("paired adapter trim failed: \(String(result.stderr.suffix(500)))") }

        case .qualityTrim:
            var args = [
                "-i", currentR1.path, "-I", r2.path,
                "-o", outR1.path, "-O", outR2.path,
                "-w", String(threads),
                "-W", String(step.windowSize ?? 4),
                "-M", String(step.qualityThreshold ?? 20),
                "--disable_adapter_trimming", "--disable_quality_filtering",
                "--disable_length_filtering",
                "--json", "/dev/null", "--html", "/dev/null",
            ]
            switch step.qualityTrimMode ?? .cutRight {
            case .cutRight: args.append("--cut_right")
            case .cutFront: args.append("--cut_front")
            case .cutTail: args.append("--cut_tail")
            case .cutBoth: args += ["--cut_front", "--cut_right"]
            }
            let result = try await runner.run(.fastp, arguments: args, timeout: 3600)
            guard result.isSuccess else { throw FASTQIngestionError.clumpifyFailed("paired quality trim failed: \(String(result.stderr.suffix(500)))") }

        default:
            break
        }

        let duration = Date().timeIntervalSince(stepStart)
        stepResults.append(RecipeStepResult(
            stepName: step.displaySummary, tool: step.toolUsed ?? step.kind.rawValue,
            toolVersion: step.toolVersion, commandLine: nil, durationSeconds: duration
        ))
        log(.stepComplete(sample: pair.sampleName, step: step.kind.rawValue, durationSeconds: duration))
        printProgress("  \u{2192} \(step.displaySummary)... done (\(Int(duration))s)")

        // CRITICAL: Clean up previous step's intermediates
        if let prev1 = previousR1 { try? fm.removeItem(at: prev1) }
        if let prev2 = previousR2 { try? fm.removeItem(at: prev2) }

        previousR1 = outR1
        previousR2 = outR2
        currentR1 = outR1
        currentR2 = outR2
        consumedPairedSteps += 1
    }

    // Interleave for remaining steps
    let interleavedURL = workspace.appendingPathComponent("interleaved.fastq")
    if let r2 = currentR2 {
        try await interleavePairedInput(r1: currentR1, r2: r2, output: interleavedURL)
        // Clean up last paired intermediates
        if let prev1 = previousR1 { try? fm.removeItem(at: prev1) }
        if let prev2 = previousR2 { try? fm.removeItem(at: prev2) }
    }

    let remainingSteps = Array(recipe.steps.dropFirst(consumedPairedSteps))
    guard !remainingSteps.isEmpty else {
        return (currentR2 != nil ? interleavedURL : currentR1, stepResults)
    }

    // Run remaining steps via FASTQDerivativeService
    let derivativeService = FASTQDerivativeService()
    var currentURL = interleavedURL
    var previousURL: URL? = nil

    for (relIndex, step) in remainingSteps.enumerated() {
        let absIndex = consumedPairedSteps + relIndex
        let stepStart = Date()
        log(.stepStart(sample: pair.sampleName, step: step.kind.rawValue, stepIndex: absIndex + 1, totalSteps: recipe.steps.count))
        printProgress("  \u{2192} \(step.displaySummary)...")

        let engine = BatchProcessingEngine(derivativeService: derivativeService, maxConcurrency: 1)
        let request = try engine.convertStepToRequest(step)
        let outputURL = try await derivativeService.createDerivative(
            from: currentURL,
            request: request,
            progress: { _ in }
        )

        let duration = Date().timeIntervalSince(stepStart)
        stepResults.append(RecipeStepResult(
            stepName: step.displaySummary, tool: step.toolUsed ?? step.kind.rawValue,
            toolVersion: step.toolVersion, commandLine: nil, durationSeconds: duration
        ))
        log(.stepComplete(sample: pair.sampleName, step: step.kind.rawValue, durationSeconds: duration))
        printProgress("  \u{2192} \(step.displaySummary)... done (\(Int(duration))s)")

        // Clean up previous step output
        if let prev = previousURL { try? FileManager.default.removeItem(at: prev) }
        previousURL = currentURL
        currentURL = outputURL
    }

    // Clean up last intermediate
    if let prev = previousURL { try? FileManager.default.removeItem(at: prev) }

    return (currentURL, stepResults)
}

// MARK: - Helpers

private static func createIngestionWorkspace(anchoredAt anchor: URL) throws -> URL {
    let fm = FileManager.default
    do {
        return try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor, create: true)
    } catch {
        let fallback = fm.temporaryDirectory.appendingPathComponent("fastq-import-\(UUID().uuidString)")
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}

private static func interleavePairedInput(r1: URL, r2: URL, output: URL) async throws {
    let runner = NativeToolRunner.shared
    let env = await bbToolsEnvironment()
    let result = try await runner.run(
        .reformat,
        arguments: ["in1=\(r1.path)", "in2=\(r2.path)", "out=\(output.path)", "interleaved=t", "ow=t"],
        environment: env,
        timeout: 3600
    )
    guard result.isSuccess else {
        throw FASTQIngestionError.clumpifyFailed("reformat.sh interleave failed: \(String(result.stderr.suffix(500)))")
    }
}

private static func bbToolsEnvironment() async -> [String: String] {
    let runner = NativeToolRunner.shared
    let toolsDir = await runner.getToolsDirectory()
    var env: [String: String] = [:]
    if let toolsDir {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
        env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
        let javaURL = jreBinDir.appendingPathComponent("java")
        if FileManager.default.fileExists(atPath: javaURL.path) {
            env["JAVA_HOME"] = toolsDir.appendingPathComponent("jre").path
            env["BBMAP_JAVA"] = javaURL.path
        }
    }
    return env
}

private static func fileSizeSum(_ urls: [URL]) -> Int64 {
    urls.reduce(Int64(0)) { total, url in
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return total + (attrs?[.size] as? Int64 ?? 0)
    }
}

private static func bundleFileSize(_ bundleURL: URL) -> Int64 {
    guard let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else { return 0 }
    let attrs = try? FileManager.default.attributesOfItem(atPath: fastqURL.path)
    return (attrs?[.size] as? Int64) ?? 0
}

private static func writePerSampleLog(pair: SamplePair, bundleURL: URL, logDir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logFile = logDir.appendingPathComponent("\(pair.sampleName).log")
    let content = """
    Sample: \(pair.sampleName)
    R1: \(pair.r1.path)
    R2: \(pair.r2?.path ?? "n/a")
    Bundle: \(bundleURL.path)
    Completed: \(ISO8601DateFormatter().string(from: Date()))
    """
    try content.write(to: logFile, atomically: true, encoding: .utf8)
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter FASTQBatchImporterTests 2>&1 | tail -10`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift
git commit -m "feat: add sequential sample processing with memory safety

FASTQBatchImporter.runBatchImport processes samples one at a time with:
- autoreleasepool boundaries between samples
- intermediate file deletion between recipe steps
- bounded stderr capture via maxStderrBytes
- per-sample log files for debugging
- skip-if-exists for basic resumability"
```

---

## Task 7: CLI Command — ImportFastqCommand

Wire the FASTQBatchImporter into an ArgumentParser command.

**Files:**
- Create: `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift:51-60`
- Test: `Tests/LungfishCLITests/ImportFastqCommandTests.swift`

- [ ] **Step 1: Write failing tests for CLI argument parsing**

Create `Tests/LungfishCLITests/ImportFastqCommandTests.swift`:

```swift
// ImportFastqCommandTests.swift
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import ArgumentParser

final class ImportFastqCommandTests: XCTestCase {

    func testParseMinimalArguments() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertEqual(command.input, "/data/fastq_dir")
        XCTAssertEqual(command.project, "/projects/Test.lungfish")
        XCTAssertEqual(command.recipe, "none")
        XCTAssertFalse(command.dryRun)
    }

    func testParseFullArguments() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
            "--recipe", "vsp2",
            "--quality-binning", "illumina4",
            "--threads", "16",
            "--log-dir", "/tmp/logs",
            "--dry-run",
        ])
        XCTAssertEqual(command.recipe, "vsp2")
        XCTAssertEqual(command.qualityBinning, "illumina4")
        XCTAssertEqual(command.threads, 16)
        XCTAssertEqual(command.logDir, "/tmp/logs")
        XCTAssertTrue(command.dryRun)
    }

    func testParseDefaultThreads() throws {
        let command = try ImportCommand.FastqSubcommand.parse([
            "/data/fastq_dir",
            "--project", "/projects/Test.lungfish",
        ])
        XCTAssertNil(command.threads)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ImportFastqCommandTests 2>&1 | tail -5`
Expected: FAIL — `FastqSubcommand` doesn't exist.

- [ ] **Step 3: Implement ImportFastqCommand**

Create `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`:

```swift
// ImportFastqCommand.swift - CLI command for batch FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ImportCommand {

    /// Import FASTQ files into a Lungfish project with optional recipe processing.
    ///
    /// Processes paired-end samples sequentially with memory-safe intermediate
    /// cleanup. Supports built-in recipes (VSP2, WGS, amplicon, HiFi).
    ///
    /// ## Examples
    ///
    /// ```
    /// # Dry run — list detected pairs
    /// lungfish import fastq /data/run_dir --project ./Test.lungfish --recipe vsp2 --dry-run
    ///
    /// # Import with VSP2 recipe
    /// lungfish import fastq /data/run_dir --project ./Test.lungfish --recipe vsp2
    ///
    /// # Import without recipe (clumpify + compress only)
    /// lungfish import fastq /data/run_dir --project ./Test.lungfish
    /// ```
    struct FastqSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fastq",
            abstract: "Import FASTQ files with optional recipe processing"
        )

        @Argument(help: "Directory containing .fastq.gz files, or explicit file paths")
        var input: String

        @Option(
            name: [.customLong("project"), .customShort("p")],
            help: "Path to .lungfish project directory"
        )
        var project: String

        @Option(
            name: .customLong("recipe"),
            help: "Processing recipe: vsp2, wgs, amplicon, hifi, none (default: none)"
        )
        var recipe: String = "none"

        @Option(
            name: .customLong("quality-binning"),
            help: "Quality binning scheme: illumina4, eightLevel, none (default: illumina4)"
        )
        var qualityBinning: String = "illumina4"

        @Option(
            name: .customLong("threads"),
            help: "Thread count for tools (default: all cores)"
        )
        var threads: Int?

        @Option(
            name: .customLong("log-dir"),
            help: "Directory for per-sample log files"
        )
        var logDir: String?

        @Flag(
            name: .customLong("dry-run"),
            help: "List detected pairs without importing"
        )
        var dryRun: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: input)
            let projectURL = URL(fileURLWithPath: project)

            // Validate project exists
            guard FileManager.default.fileExists(atPath: projectURL.path) else {
                throw BatchImportError.projectNotFound(projectURL)
            }

            // Detect pairs
            let pairs: [SamplePair]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir), isDir.boolValue {
                pairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
            } else {
                // Single file or glob — treat as explicit files
                pairs = FASTQBatchImporter.detectPairs(from: [inputURL])
            }

            print(formatter.info("Detected \(pairs.count) sample(s):"))
            for (i, pair) in pairs.enumerated() {
                let r2Str = pair.r2.map { " + \($0.lastPathComponent)" } ?? " (single-end)"
                print("  \(i + 1). \(pair.sampleName): \(pair.r1.lastPathComponent)\(r2Str)")
            }

            if dryRun {
                print(formatter.info("\nDry run — no files imported."))
                return
            }

            // Resolve recipe
            let resolvedRecipe: ProcessingRecipe?
            if recipe.lowercased() == "none" {
                resolvedRecipe = nil
            } else {
                resolvedRecipe = try FASTQBatchImporter.resolveRecipe(named: recipe)
                print(formatter.info("Recipe: \(resolvedRecipe!.name) (\(resolvedRecipe!.steps.count) steps)"))
            }

            // Resolve quality binning
            let binning: QualityBinningScheme
            switch qualityBinning.lowercased() {
            case "illumina4": binning = .illumina4
            case "eightlevel": binning = .eightLevel
            case "none": binning = .none
            default: binning = .illumina4
            }

            let threadCount = threads ?? ProcessInfo.processInfo.activeProcessorCount
            let logDirectory = logDir.map { URL(fileURLWithPath: $0) }

            let config = FASTQBatchImporter.ImportConfig(
                projectDirectory: projectURL,
                recipe: resolvedRecipe,
                qualityBinning: binning,
                threads: threadCount,
                logDirectory: logDirectory
            )

            print(formatter.info("Starting import (\(threadCount) threads, \(binning.rawValue) binning)...\n"))

            let result = await FASTQBatchImporter.runBatchImport(
                pairs: pairs,
                config: config,
                log: { event in
                    // Write JSON to stdout for machine consumption
                    let json = FASTQBatchImporter.encodeLogEvent(event)
                    print(json)
                }
            )

            if result.failed > 0 {
                print(formatter.warning("\n\(result.failed) sample(s) failed:"))
                for (sample, error) in result.errors {
                    print(formatter.error("  \(sample): \(error)"))
                }
            }
        }
    }
}
```

- [ ] **Step 4: Register FastqSubcommand in ImportCommand**

In `Sources/LungfishCLI/Commands/ImportCommand.swift`, add to the subcommands array (line 51-60):

```swift
subcommands: [
    BAMSubcommand.self,
    VCFSubcommand.self,
    FASTASubcommand.self,
    Kraken2Subcommand.self,
    EsVirituSubcommand.self,
    TaxTriageSubcommand.self,
    NaoMgsSubcommand.self,
    NvdSubcommand.self,
    FastqSubcommand.self,
]
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter ImportFastqCommandTests 2>&1 | tail -10`
Expected: All 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/ImportFastqCommand.swift Sources/LungfishCLI/Commands/ImportCommand.swift Tests/LungfishCLITests/ImportFastqCommandTests.swift
git commit -m "feat: add lungfish import fastq CLI command

ArgumentParser command for batch FASTQ import with --recipe, --dry-run,
--threads, --quality-binning, --log-dir options. Wraps FASTQBatchImporter
for CLI usage. Registered as subcommand of lungfish import."
```

---

## Task 8: Integration Tests with Test Fixtures

End-to-end tests using the SARS-CoV-2 test fixtures.

**Files:**
- Create: `Tests/LungfishIntegrationTests/FASTQBatchImportTests.swift`

- [ ] **Step 1: Write integration test for single sample import (no recipe)**

Create `Tests/LungfishIntegrationTests/FASTQBatchImportTests.swift`:

```swift
// FASTQBatchImportTests.swift
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class FASTQBatchImportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testPairDetectionFromFixtures() throws {
        let r1 = TestFixtures.sarscov2.fastqR1
        let r2 = TestFixtures.sarscov2.fastqR2
        let pairs = FASTQBatchImporter.detectPairs(from: [r1, r2])
        XCTAssertEqual(pairs.count, 1, "Should detect one paired sample")
        XCTAssertNotNil(pairs.first?.r2, "Should detect R2")
        XCTAssertEqual(pairs.first?.sampleName, "test")
    }

    func testSkipExistingBundle() throws {
        let projectDir = tempDir!
        let pair = SamplePair(
            sampleName: "test",
            r1: TestFixtures.sarscov2.fastqR1,
            r2: TestFixtures.sarscov2.fastqR2
        )

        // No bundle yet
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: projectDir))

        // Create fake bundle
        let bundleDir = projectDir.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        XCTAssertTrue(FASTQBatchImporter.bundleExists(for: pair, in: projectDir))
    }

    func testStructuredLogEvents() throws {
        var events: [String] = []

        let event = ImportLogEvent.sampleStart(
            sample: "test", index: 1, total: 1,
            r1: "test_1.fastq.gz", r2: "test_2.fastq.gz"
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        events.append(json)

        XCTAssertTrue(events[0].contains("\"event\":\"sample_start\""))
        XCTAssertTrue(events[0].contains("\"sample\":\"test\""))
    }
}
```

- [ ] **Step 2: Run integration tests**

Run: `swift test --filter FASTQBatchImportTests 2>&1 | tail -10`
Expected: All 3 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/FASTQBatchImportTests.swift
git commit -m "test: add integration tests for FASTQ batch import

Tests pair detection with real fixtures, skip-if-exists logic, and
structured log event encoding."
```

---

## Task 9: GUI Integration — Spawn CLI as Subprocess

Wire the GUI drag-and-drop path to spawn `lungfish import fastq` instead of running the pipeline inline.

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift`

- [ ] **Step 1: Add CLI subprocess spawn method to FASTQIngestionService**

Add a new method to `Sources/LungfishApp/Services/FASTQIngestionService.swift`, after the existing `ingestAndBundle` overloads:

```swift
// MARK: - CLI Subprocess Import

/// Spawns `lungfish import fastq` as a child process for memory-safe batch import.
///
/// Progress is parsed from the CLI's stdout JSON lines. The app stays alive
/// even if the CLI process is killed by jetsam.
public static func importViaSubprocess(
    inputDirectory: URL,
    projectDirectory: URL,
    recipe: String,
    qualityBinning: QualityBinningScheme = .illumina4,
    completion: @escaping @MainActor (Result<Int, Error>) -> Void
) {
    let title = "FASTQ Batch Import"
    let cliCmd = "lungfish import fastq \(inputDirectory.path) --project \(projectDirectory.path) --recipe \(recipe)"
    let opID = OperationCenter.shared.start(
        title: title,
        detail: "Starting batch import\u{2026}",
        operationType: .ingestion,
        cliCommand: cliCmd
    )

    let task = Task.detached {
        await Self.runCLISubprocess(
            inputDirectory: inputDirectory,
            projectDirectory: projectDirectory,
            recipe: recipe,
            qualityBinning: qualityBinning,
            operationID: opID,
            completion: completion
        )
    }

    OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
}

nonisolated private static func runCLISubprocess(
    inputDirectory: URL,
    projectDirectory: URL,
    recipe: String,
    qualityBinning: QualityBinningScheme,
    operationID opID: UUID,
    completion: @escaping @MainActor (Result<Int, Error>) -> Void
) async {
    do {
        // Find the CLI executable (same bundle as the app)
        let appBundle = Bundle.main
        let cliURL: URL
        if let bundledCLI = appBundle.url(forAuxiliaryExecutable: "lungfish") {
            cliURL = bundledCLI
        } else {
            // Development fallback: look for built CLI
            let buildDir = appBundle.executableURL!.deletingLastPathComponent()
            cliURL = buildDir.appendingPathComponent("lungfish")
        }

        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            throw BatchImportError.projectNotFound(cliURL) // reuse error for "CLI not found"
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = [
            "import", "fastq",
            inputDirectory.path,
            "--project", projectDirectory.path,
            "--recipe", recipe,
            "--quality-binning", qualityBinning.rawValue,
            "--threads", String(ProcessInfo.processInfo.activeProcessorCount),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Parse JSON lines from stdout for progress updates
        let handle = stdoutPipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            guard let line = String(data: data, encoding: .utf8) else { continue }

            for jsonLine in line.split(separator: "\n") {
                guard let jsonData = jsonLine.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let event = dict["event"] as? String else { continue }

                let detail: String
                let progress: Double?

                switch event {
                case "sample_start":
                    let sample = dict["sample"] as? String ?? "?"
                    let index = dict["index"] as? Int ?? 0
                    let total = dict["total"] as? Int ?? 0
                    detail = "[\(index)/\(total)] \(sample)"
                    progress = Double(index - 1) / Double(max(1, total))
                case "step_start":
                    let sample = dict["sample"] as? String ?? "?"
                    let step = dict["step"] as? String ?? "?"
                    detail = "\(sample): \(step)"
                    progress = nil
                case "sample_complete":
                    let sample = dict["sample"] as? String ?? "?"
                    detail = "\(sample): complete"
                    progress = nil
                case "sample_skip":
                    let sample = dict["sample"] as? String ?? "?"
                    detail = "\(sample): skipped (already exists)"
                    progress = nil
                case "import_complete":
                    let completed = dict["completed"] as? Int ?? 0
                    detail = "Import complete: \(completed) samples"
                    progress = 1.0
                default:
                    continue
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let p = progress {
                            OperationCenter.shared.update(id: opID, progress: p, detail: detail)
                        } else {
                            OperationCenter.shared.update(id: opID, detail: detail)
                        }
                    }
                }
            }
        }

        process.waitUntilExit()

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.complete(id: opID, detail: "Batch import complete", bundleURLs: [])
                    completion(.success(Int(exitCode)))
                }
            }
        } else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "Exit code \(exitCode): \(String(stderrStr.suffix(200)))")
                    completion(.failure(BatchImportError.projectNotFound(URL(fileURLWithPath: stderrStr))))
                }
            }
        }

    } catch {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OperationCenter.shared.fail(id: opID, detail: "\(error)")
                completion(.failure(error))
            }
        }
    }
}
```

- [ ] **Step 2: Run existing tests to verify no regressions**

Run: `swift test 2>&1 | grep -E "(Test Suite|failed|passed)" | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQIngestionService.swift
git commit -m "feat: add CLI subprocess spawn path for batch FASTQ import

FASTQIngestionService.importViaSubprocess spawns lungfish import fastq
as a child process. Parses JSON stdout lines for OperationCenter
progress. App stays alive even if the import process is killed."
```

---

## Task 10: Final Verification and Build

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | grep -E "(Test Suite|failed|passed)" | tail -20`
Expected: All tests pass including new ones.

- [ ] **Step 2: Build CLI and verify help output**

Run: `swift build --product LungfishCLI 2>&1 | tail -5 && .build/debug/lungfish import fastq --help`
Expected: Help output showing all arguments matching the spec.

- [ ] **Step 3: Verify dry-run against real data**

Run: `.build/debug/lungfish import fastq /Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3 --project /Volumes/nvd_remote/Test-2026-04-03/Test.lungfish --recipe vsp2 --dry-run`
Expected: Lists all 52 paired samples without importing.

- [ ] **Step 4: Commit any fixes from verification**

If any fixes were needed, commit them with a descriptive message.

- [ ] **Step 5: Test single-sample import against real data**

Run: `.build/debug/lungfish import fastq /Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R1_001.fastq.gz /Volumes/nvd_remote/20260324_LH00283_0311_A23J2LGLT3/School001-20260216_S132_L008_R2_001.fastq.gz --project /Volumes/nvd_remote/Test-2026-04-03/Test.lungfish --recipe vsp2`
Expected: Processes one sample successfully, creates bundle in project.
