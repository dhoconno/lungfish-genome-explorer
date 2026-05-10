# Markdup Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace brittle Swift-side position+strand dedup with `samtools markdup` as the canonical duplicate detection across all four classifier tools (TaxTriage, EsViritu, NVD, NAO-MGS), with a standalone `lungfish-cli markdup` command and thorough functional tests.

**Architecture:** New `MarkdupService` module in `LungfishIO` wraps the streamed samtools pipeline (`sort -n | fixmate -m | sort | markdup`) with atomic in-place BAM replacement and idempotency via the `@PG ID:samtools.markdup` header marker. New `MarkdupCommand` CLI wraps the service for standalone use. `BuildDbCommand` calls `MarkdupService.markdup()` directly as a Swift function before counting reads. `NaoMgsBamMaterializer` synthesizes real BAMs from NAO-MGS SQLite rows so NAO-MGS joins the same pipeline. `MiniBAMViewController` filters duplicates via `samtools view -F 0x404` and deletes its Swift-side dedup logic.

**Tech Stack:** Swift 6.2, samtools 1.23+, raw sqlite3 C API, ArgumentParser CLI, `Process` + `Pipe` for subprocess management

**Spec:** `docs/superpowers/specs/2026-04-08-markdup-service-design.md`

**Branch:** `feature/batch-aggregated-classifier-views` (continue current branch)

---

## File Map

### New Files
- `Sources/LungfishIO/Services/MarkdupService.swift` — public API for markdup pipeline + countReads helper
- `Sources/LungfishIO/Services/MarkdupResult.swift` — `MarkdupResult` struct + `MarkdupError` enum
- `Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift` — SAM synthesis from NAO-MGS SQLite rows
- `Sources/LungfishCLI/Commands/MarkdupCommand.swift` — `lungfish-cli markdup` subcommand
- `Tests/LungfishIOTests/TestSupport/BamFixtureBuilder.swift` — test helper to generate synthetic BAMs
- `Tests/LungfishIOTests/MarkdupServiceTests.swift` — unit tests
- `Tests/LungfishIOTests/NaoMgsBamMaterializerTests.swift` — unit tests
- `Tests/LungfishCLITests/MarkdupCommandTests.swift` — CLI integration tests
- `Tests/LungfishCLITests/BuildDbCommandMarkdupTests.swift` — build-db + markdup integration tests

### Modified Files
- `Sources/LungfishCLI/LungfishCLI.swift` — register `MarkdupCommand.self` in subcommands list
- `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — `updateUniqueReadsInDB` calls `MarkdupService.markdup()`, then counts via `MarkdupService.countReads()`
- `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift` — add `unique_reads INTEGER` column to `blast_hits`, schema migration on read, update bulk insert
- `Sources/LungfishCLI/Commands/NvdCommand.swift` — call `MarkdupService.markdupDirectory()` after BAM import, populate `unique_reads` column
- `Sources/LungfishCLI/Commands/NaoMgsCommand.swift` — call `NaoMgsBamMaterializer.materializeAll()` after DB creation
- `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift` — delete `detectDuplicates`, `allDuplicateIndices`, `pcrDuplicateReadCount`, `applyDuplicateVisibility`; change `fetchReads` to use `excludeFlags: 0x404`; delete `displayReads(reads:)` path
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` — switch from `displayReads()` to `displayContig()` using derived BAM path

---

## Dependencies Between Tasks

- Task 1 (`MarkdupResult` types) → Task 2 (`MarkdupService`) → Task 3 (`MarkdupCommand`)
- Task 2 → Task 4 (BuildDbCommand integration)
- Task 5 (`BamFixtureBuilder`) → Task 6 (MarkdupService tests)
- Task 7 (NVD schema migration) → Task 8 (NVD import integration)
- Task 9 (`NaoMgsBamMaterializer`) → Task 10 (NAO-MGS import integration) → Task 11 (NAO-MGS viewer switch)
- Task 12 (viewer cleanup) can run after Task 4

Tasks 1-4 must come first because everything depends on `MarkdupService`. Tasks 7-11 (NVD + NAO-MGS) can be done in parallel with each other after Task 4.

---

## Task 1: MarkdupResult and MarkdupError Types

Create the result struct and error enum that `MarkdupService` will throw/return. Tiny isolated task, no dependencies.

**Files:**
- Create: `Sources/LungfishIO/Services/MarkdupResult.swift`

- [ ] **Step 1: Create the file with types**

```swift
// MarkdupResult.swift - Result and error types for MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Outcome of a markdup operation on a single BAM file.
public struct MarkdupResult: Sendable {
    /// Absolute path to the BAM that was processed (unchanged after in-place replacement).
    public let bamURL: URL
    /// True if the BAM already had a `@PG ID:samtools.markdup` header and was skipped.
    public let wasAlreadyMarkduped: Bool
    /// Total mapped reads after markdup (samtools view -c -F 0x004).
    public let totalReads: Int
    /// Reads flagged as duplicates (totalReads - nonDuplicateReads).
    public let duplicateReads: Int
    /// Wall-clock time for the full pipeline including indexing.
    public let durationSeconds: Double

    public init(
        bamURL: URL,
        wasAlreadyMarkduped: Bool,
        totalReads: Int,
        duplicateReads: Int,
        durationSeconds: Double
    ) {
        self.bamURL = bamURL
        self.wasAlreadyMarkduped = wasAlreadyMarkduped
        self.totalReads = totalReads
        self.duplicateReads = duplicateReads
        self.durationSeconds = durationSeconds
    }
}

/// Errors from `MarkdupService` operations.
public enum MarkdupError: Error, LocalizedError, Sendable {
    case toolNotFound
    case fileNotFound(URL)
    case pipelineFailed(stage: String, stderr: String)
    case indexFailed(stderr: String)
    case corruptOutput(reason: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "samtools binary not found"
        case .fileNotFound(let url):
            return "BAM file not found: \(url.path)"
        case .pipelineFailed(let stage, let stderr):
            return "markdup pipeline failed at stage '\(stage)': \(stderr)"
        case .indexFailed(let stderr):
            return "samtools index failed: \(stderr)"
        case .corruptOutput(let reason):
            return "markdup produced corrupt output: \(reason)"
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishIO/Services/MarkdupResult.swift
git commit -m "feat: add MarkdupResult and MarkdupError types"
```

---

## Task 2: MarkdupService Core

Implement the `MarkdupService` enum with the streamed pipeline, idempotency check, atomic replacement, and `countReads` helper.

**Files:**
- Create: `Sources/LungfishIO/Services/MarkdupService.swift`

- [ ] **Step 1: Create the file with MarkdupService**

```swift
// MarkdupService.swift - Runs samtools markdup pipeline on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "MarkdupService")

/// Runs the canonical samtools PCR-duplicate-marking pipeline on BAM files.
///
/// Pipeline: `samtools sort -n | fixmate -m | sort | markdup` followed by `samtools index`.
/// The output replaces the input atomically. Idempotent via the `@PG ID:samtools.markdup`
/// header line that `samtools markdup` adds automatically.
public enum MarkdupService {

    // MARK: - Public API

    /// Runs markdup in-place on a single BAM file.
    @discardableResult
    public static func markdup(
        bamURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> MarkdupResult {
        let start = Date()

        guard FileManager.default.fileExists(atPath: bamURL.path) else {
            throw MarkdupError.fileNotFound(bamURL)
        }

        // Idempotency check
        if !force && isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath) {
            let total = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath)) ?? 0
            let nonDup = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath)) ?? 0
            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: true,
                totalReads: total,
                duplicateReads: max(0, total - nonDup),
                durationSeconds: Date().timeIntervalSince(start)
            )
        }

        // Run the pipeline
        let tempBamURL = URL(fileURLWithPath: bamURL.path + ".markdup.tmp")
        let tempBaiURL = URL(fileURLWithPath: tempBamURL.path + ".bai")

        // Clean up any stale temp files from a previous failed run
        try? FileManager.default.removeItem(at: tempBamURL)
        try? FileManager.default.removeItem(at: tempBaiURL)

        do {
            try runPipeline(
                inputPath: bamURL.path,
                outputPath: tempBamURL.path,
                samtoolsPath: samtoolsPath,
                threads: threads
            )

            // Verify the output exists and is non-empty
            guard FileManager.default.fileExists(atPath: tempBamURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: tempBamURL.path),
                  let size = attrs[.size] as? Int, size > 0 else {
                throw MarkdupError.corruptOutput(reason: "output BAM missing or empty at \(tempBamURL.path)")
            }

            try runIndex(bamPath: tempBamURL.path, samtoolsPath: samtoolsPath)

            // Atomic replacement: remove existing .bai first, then swap both files.
            let existingBaiURL = URL(fileURLWithPath: bamURL.path + ".bai")
            try? FileManager.default.removeItem(at: existingBaiURL)
            _ = try FileManager.default.replaceItemAt(bamURL, withItemAt: tempBamURL)
            if FileManager.default.fileExists(atPath: tempBaiURL.path) {
                try FileManager.default.moveItem(at: tempBaiURL, to: existingBaiURL)
            }
        } catch {
            // Clean up temp files on failure
            try? FileManager.default.removeItem(at: tempBamURL)
            try? FileManager.default.removeItem(at: tempBaiURL)
            throw error
        }

        // Count reads post-markdup for the result
        let total = try countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath)
        let nonDup = try countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath)

        logger.info("Marked duplicates in \(bamURL.lastPathComponent, privacy: .public): \(total - nonDup)/\(total)")

        return MarkdupResult(
            bamURL: bamURL,
            wasAlreadyMarkduped: false,
            totalReads: total,
            duplicateReads: max(0, total - nonDup),
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    /// Runs markdup on every `.bam` file in a directory tree.
    @discardableResult
    public static func markdupDirectory(
        _ dirURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> [MarkdupResult] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [MarkdupResult] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "bam" else { continue }
            // Skip .bai/.csi files even if the enumerator finds them (they don't have .bam ext but defensive)
            let result = try markdup(
                bamURL: fileURL,
                samtoolsPath: samtoolsPath,
                threads: threads,
                force: force
            )
            results.append(result)
        }
        return results
    }

    /// Checks whether a BAM has already been processed by samtools markdup.
    public static func isAlreadyMarkduped(bamURL: URL, samtoolsPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["view", "-H", bamURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let header = String(data: data, encoding: .utf8) else {
            return false
        }
        // samtools markdup adds a @PG line with ID:samtools.markdup
        return header.contains("ID:samtools.markdup")
    }

    /// Counts reads in a BAM matching a flag filter, optionally restricted to an accession.
    ///
    /// Wrapper around `samtools view -c -F <flagFilter> <bam> [accession]`.
    public static func countReads(
        bamURL: URL,
        accession: String?,
        flagFilter: Int,
        samtoolsPath: String
    ) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        var args = ["view", "-c", "-F", String(flagFilter), bamURL.path]
        if let accession, !accession.isEmpty {
            args.append(accession)
        }
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.pipelineFailed(stage: "count", stderr: stderr)
        }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(output) ?? 0
    }

    // MARK: - Private Helpers

    /// Runs the 4-stage pipeline via /bin/sh -c to use native shell piping.
    private static func runPipeline(
        inputPath: String,
        outputPath: String,
        samtoolsPath: String,
        threads: Int
    ) throws {
        let cmd = """
        "\(samtoolsPath)" sort -n -@ \(threads) "\(inputPath)" | \
        "\(samtoolsPath)" fixmate -m - - | \
        "\(samtoolsPath)" sort -@ \(threads) - | \
        "\(samtoolsPath)" markdup - "\(outputPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MarkdupError.pipelineFailed(stage: "launch", stderr: error.localizedDescription)
        }

        // Drain stderr asynchronously to avoid pipe-full deadlock on large outputs
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.pipelineFailed(stage: "markdup-pipeline", stderr: stderr)
        }
    }

    /// Runs `samtools index` on a BAM file.
    private static func runIndex(bamPath: String, samtoolsPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["index", bamPath]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MarkdupError.indexFailed(stderr: error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.indexFailed(stderr: stderr)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishIO/Services/MarkdupService.swift
git commit -m "feat: add MarkdupService with samtools markdup pipeline"
```

---

## Task 3: BamFixtureBuilder Test Helper

Create a test helper that generates synthetic BAM files with known content. Used by multiple test suites.

**Files:**
- Create: `Tests/LungfishIOTests/TestSupport/BamFixtureBuilder.swift`

- [ ] **Step 1: Create the file**

```swift
// BamFixtureBuilder.swift - Test helper to generate synthetic BAM files.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Test helper that generates a minimal BAM file from explicit SAM content,
/// using samtools to compress. Used by tests that need synthetic BAM data
/// with known read/duplicate patterns.
enum BamFixtureBuilder {

    struct Reference {
        let name: String
        let length: Int
    }

    struct Read {
        let qname: String
        let flag: Int
        let rname: String
        let pos: Int         // 1-based
        let mapq: Int
        let cigar: String
        let seq: String
        let qual: String
    }

    /// Creates an indexed, coordinate-sorted BAM at `outputURL` from the given references and reads.
    /// Requires samtools to be available.
    static func makeBAM(
        at outputURL: URL,
        references: [Reference],
        reads: [Read],
        samtoolsPath: String
    ) throws {
        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Build SAM text
        var sam = "@HD\tVN:1.6\tSO:coordinate\n"
        for ref in references {
            sam += "@SQ\tSN:\(ref.name)\tLN:\(ref.length)\n"
        }
        for read in reads {
            sam += "\(read.qname)\t\(read.flag)\t\(read.rname)\t\(read.pos)\t\(read.mapq)\t\(read.cigar)\t*\t0\t0\t\(read.seq)\t\(read.qual)\n"
        }

        // Write to intermediate SAM file, then convert + sort via samtools
        let samURL = outputURL.deletingPathExtension().appendingPathExtension("sam")
        try sam.write(to: samURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: samURL) }

        // samtools sort -o output.bam input.sam (coordinate sort by default)
        let sortProc = Process()
        sortProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        sortProc.arguments = ["sort", "-o", outputURL.path, samURL.path]
        let errPipe = Pipe()
        sortProc.standardOutput = FileHandle.nullDevice
        sortProc.standardError = errPipe
        try sortProc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        sortProc.waitUntilExit()
        guard sortProc.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "BamFixtureBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "samtools sort failed: \(stderr)"])
        }

        // Index
        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", outputURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        indexProc.standardError = FileHandle.nullDevice
        try indexProc.run()
        indexProc.waitUntilExit()
        guard indexProc.terminationStatus == 0 else {
            throw NSError(domain: "BamFixtureBuilder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "samtools index failed"])
        }
    }

    /// Convenience: returns the path to samtools if available, or nil if not.
    static func locateSamtools() -> String? {
        let candidates = [
            "/opt/homebrew/Cellar/samtools/1.23/bin/samtools",
            "/opt/homebrew/bin/samtools",
            "/usr/local/bin/samtools",
            "/usr/bin/samtools",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIOTests/TestSupport/BamFixtureBuilder.swift
git commit -m "test: add BamFixtureBuilder helper for synthetic BAM generation"
```

---

## Task 4: MarkdupService Unit Tests

Write the full unit test suite for `MarkdupService` using `BamFixtureBuilder` and the existing `taxtriage-mini` BAM fixture.

**Files:**
- Create: `Tests/LungfishIOTests/MarkdupServiceTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// MarkdupServiceTests.swift - Unit tests for MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class MarkdupServiceTests: XCTestCase {

    private var samtoolsPath: String {
        guard let path = BamFixtureBuilder.locateSamtools() else {
            XCTFail("samtools not available; cannot run markdup tests")
            return ""
        }
        return path
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupSvcTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a BAM with 5 reads at the same position (all duplicates of each other
    /// by position+strand heuristic).
    private func makeBamWithDuplicates(at url: URL) throws {
        let refs = [BamFixtureBuilder.Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            BamFixtureBuilder.Read(
                qname: "read\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        try BamFixtureBuilder.makeBAM(at: url, references: refs, reads: reads, samtoolsPath: samtoolsPath)
    }

    // MARK: - Basic operation

    func testMarkdupOnSyntheticBAM() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertFalse(result.wasAlreadyMarkduped, "First call should not be a no-op")
        XCTAssertEqual(result.totalReads, 5, "All 5 reads should be counted as total")
        XCTAssertGreaterThan(result.duplicateReads, 0, "At least some reads should be marked as duplicates")
    }

    func testMarkdupGeneratesIndex() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baiURL.path), ".bai file must exist after markdup")
    }

    func testMarkdupPreservesCoordinateSortOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        // Read the header and verify SO:coordinate
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["view", "-H", bamURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let header = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(header.contains("SO:coordinate"), "Output BAM must be coordinate-sorted")
    }

    // MARK: - Idempotency

    func testIsAlreadyMarkdupedFalseOnUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        XCTAssertFalse(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath))
    }

    func testIsAlreadyMarkdupedTrueAfterMarkdup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath))
    }

    func testMarkdupIdempotentSecondRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
        let second = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertTrue(second.wasAlreadyMarkduped, "Second run should detect existing markdup")
    }

    func testMarkdupForceReRuns() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
        let forced = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath, force: true)

        XCTAssertFalse(forced.wasAlreadyMarkduped, "Force should re-run even if already marked")
    }

    // MARK: - countReads

    func testCountReadsTotal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let total = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(total, 5)
    }

    func testCountReadsPerAccession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let chr1Count = try MarkdupService.countReads(
            bamURL: bamURL, accession: "chr1", flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(chr1Count, 5)
    }

    func testCountReadsExcludingDuplicatesAfterMarkdup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        let nonDup = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath
        )
        XCTAssertLessThan(nonDup, 5, "Non-duplicate count must be less than total 5 (all duplicates)")
    }

    // MARK: - Errors

    func testMarkdupThrowsOnMissingBAM() {
        let bamURL = URL(fileURLWithPath: "/nonexistent/path.bam")
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)) { error in
            guard case MarkdupError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Directory walking

    func testMarkdupDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bam1 = dir.appendingPathComponent("a.bam")
        let bam2 = dir.appendingPathComponent("subdir/b.bam")
        try makeBamWithDuplicates(at: bam1)
        try makeBamWithDuplicates(at: bam2)

        let results = try MarkdupService.markdupDirectory(dir, samtoolsPath: samtoolsPath)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.wasAlreadyMarkduped })
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter MarkdupServiceTests`
Expected: All 12 tests pass. If samtools isn't available at the candidate paths, tests will `XCTFail("samtools not available")`.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIOTests/MarkdupServiceTests.swift
git commit -m "test: add MarkdupService unit tests"
```

---

## Task 5: MarkdupCommand CLI

Add the `lungfish-cli markdup` standalone subcommand wrapping `MarkdupService`.

**Files:**
- Create: `Sources/LungfishCLI/Commands/MarkdupCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift` — register subcommand

- [ ] **Step 1: Create MarkdupCommand.swift**

```swift
// MarkdupCommand.swift - CLI command for running samtools markdup on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

struct MarkdupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markdup",
        abstract: "Mark PCR duplicates in BAM files using samtools markdup"
    )

    @Argument(help: "Path to a BAM file or a directory containing BAMs")
    var path: String

    @Flag(name: .long, help: "Re-run markdup even if already marked")
    var force: Bool = false

    @Option(name: .long, help: "Threads for samtools sort (default 4)")
    var threads: Int = 4

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let inputURL = URL(fileURLWithPath: path)
        let fm = FileManager.default

        guard let samtoolsPath = locateSamtools() else {
            throw ValidationError("samtools binary not found on PATH")
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw ValidationError("Path does not exist: \(inputURL.path)")
        }

        if isDir.boolValue {
            if !globalOptions.quiet {
                print("Scanning \(inputURL.path) for BAM files...")
            }
            let results = try MarkdupService.markdupDirectory(
                inputURL,
                samtoolsPath: samtoolsPath,
                threads: threads,
                force: force
            )
            if !globalOptions.quiet {
                printSummary(results)
            }
        } else {
            guard inputURL.pathExtension == "bam" else {
                throw ValidationError("File is not a .bam: \(inputURL.path)")
            }
            let result = try MarkdupService.markdup(
                bamURL: inputURL,
                samtoolsPath: samtoolsPath,
                threads: threads,
                force: force
            )
            if !globalOptions.quiet {
                printSummary([result])
            }
        }
    }

    private func printSummary(_ results: [MarkdupResult]) {
        let processed = results.count
        let skipped = results.filter { $0.wasAlreadyMarkduped }.count
        let totalReads = results.reduce(0) { $0 + $1.totalReads }
        let totalDups = results.reduce(0) { $0 + $1.duplicateReads }
        let totalTime = results.reduce(0.0) { $0 + $1.durationSeconds }

        print("Processed \(processed) BAM file\(processed == 1 ? "" : "s") (\(skipped) already marked)")
        print("Total reads: \(totalReads), duplicates: \(totalDups)")
        print(String(format: "Elapsed: %.1fs", totalTime))
    }

    private func locateSamtools() -> String? {
        let candidates = [
            "/opt/homebrew/Cellar/samtools/1.23/bin/samtools",
            "/opt/homebrew/bin/samtools",
            "/usr/local/bin/samtools",
            "/usr/bin/samtools",
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Register MarkdupCommand in LungfishCLI.swift**

Find the subcommands list (around line 32 of `Sources/LungfishCLI/LungfishCLI.swift`). Add `MarkdupCommand.self` after `BuildDbCommand.self`:

```swift
subcommands: [
    // ... existing commands ...
    BuildDbCommand.self,
    MarkdupCommand.self,   // NEW
    DebugCommand.self,
],
```

- [ ] **Step 3: Update subcommand count test**

Run: `grep -rn "subcommands.count" Tests/LungfishCLITests/`
If any test asserts a specific subcommand count, increment it by 1.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test --filter NewCommandTests 2>&1 | tail -5`
Expected: Pass or one failure about subcommand count — fix by updating the expected count and re-running.

- [ ] **Step 5: Manual smoke test**

Run: `.build/debug/lungfish-cli markdup --help 2>&1 | head -20`
Expected: Shows usage for `markdup`, listing `--force`, `--threads`, and the positional `<path>` argument.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/MarkdupCommand.swift \
      Sources/LungfishCLI/LungfishCLI.swift \
      Tests/LungfishCLITests/NewCommandTests.swift
git commit -m "feat: add lungfish-cli markdup standalone command"
```

---

## Task 6: MarkdupCommand CLI Integration Tests

Integration tests that invoke `MarkdupCommand.parse(...).run()` against real BAM fixtures.

**Files:**
- Create: `Tests/LungfishCLITests/MarkdupCommandTests.swift`

- [ ] **Step 1: Create the test file**

```swift
// MarkdupCommandTests.swift - Integration tests for lungfish-cli markdup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class MarkdupCommandTests: XCTestCase {

    private var samtoolsPath: String {
        guard let p = BamFixtureBuilder.locateSamtools() else {
            XCTFail("samtools not available")
            return ""
        }
        return p
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupCliTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSyntheticBam(at url: URL) throws {
        let refs = [BamFixtureBuilder.Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            BamFixtureBuilder.Read(
                qname: "r\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        try BamFixtureBuilder.makeBAM(at: url, references: refs, reads: reads, samtoolsPath: samtoolsPath)
    }

    func testCliMarkdupSingleBAM() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL)

        var cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
        try await cmd.run()

        // Verify the BAM now has the markdup header
        XCTAssertTrue(
            MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath),
            "BAM should be marked after CLI run"
        )
    }

    func testCliMarkdupDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bam1 = dir.appendingPathComponent("a.bam")
        let bam2 = dir.appendingPathComponent("sub/b.bam")
        try makeSyntheticBam(at: bam1)
        try makeSyntheticBam(at: bam2)

        var cmd = try MarkdupCommand.parse([dir.path, "-q"])
        try await cmd.run()

        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bam1, samtoolsPath: samtoolsPath))
        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bam2, samtoolsPath: samtoolsPath))
    }

    func testCliMarkdupSkipsAlreadyMarked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL)

        var cmd1 = try MarkdupCommand.parse([bamURL.path, "-q"])
        try await cmd1.run()
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        // Wait a moment so mtime would differ if re-written
        try await Task.sleep(nanoseconds: 1_100_000_000)

        var cmd2 = try MarkdupCommand.parse([bamURL.path, "-q"])
        try await cmd2.run()
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        XCTAssertEqual(firstMtime, secondMtime, "File should not be rewritten on second run")
    }

    func testCliMarkdupForceReruns() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL)

        var cmd1 = try MarkdupCommand.parse([bamURL.path, "-q"])
        try await cmd1.run()
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        var cmd2 = try MarkdupCommand.parse([bamURL.path, "--force", "-q"])
        try await cmd2.run()
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        XCTAssertNotEqual(firstMtime, secondMtime, "File SHOULD be rewritten on forced re-run")
    }

    func testCliMarkdupErrorsOnMissingFile() async throws {
        var cmd = try MarkdupCommand.parse(["/nonexistent/path.bam"])
        do {
            try await cmd.run()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter MarkdupCommandTests`
Expected: All 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishCLITests/MarkdupCommandTests.swift
git commit -m "test: add MarkdupCommand CLI integration tests"
```

---

## Task 7: BuildDbCommand Integration (TaxTriage + EsViritu)

Replace the position+strand dedup inside `updateUniqueReadsInDB` with `MarkdupService.markdup()` followed by `MarkdupService.countReads()` calls.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BuildDbCommand.swift` — `updateUniqueReadsInDB` function
- Create: `Tests/LungfishCLITests/BuildDbCommandMarkdupTests.swift`

- [ ] **Step 1: Rewrite updateUniqueReadsInDB**

Find `private func updateUniqueReadsInDB` (around line 198 of `BuildDbCommand.swift`). Replace the entire function body with:

```swift
private func updateUniqueReadsInDB(
    dbPath: String,
    table: String,
    sampleCol: String,
    accessionCol: String,
    bamPathCol: String,
    resultURL: URL,
    bamPathResolver: (URL, String, String) -> String,
    updateAccessionLength: Bool,
    quiet: Bool
) {
    guard let samtoolsPath = findSamtools() else {
        if !quiet { print("Warning: samtools not found, skipping unique reads computation") }
        return
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        if !quiet { print("Warning: could not open database for unique reads update") }
        return
    }
    defer { sqlite3_close(db) }

    // Query rows that have BAM + accession
    let selectSQL = "SELECT rowid, \(sampleCol), \(accessionCol), \(bamPathCol) FROM \(table) WHERE \(bamPathCol) IS NOT NULL AND \(accessionCol) IS NOT NULL AND \(accessionCol) != ''"
    var selectStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
        if !quiet { print("Warning: failed to prepare SELECT for unique reads") }
        return
    }
    defer { sqlite3_finalize(selectStmt) }

    struct RowToProcess {
        let rowid: Int64
        let sample: String
        let accession: String
        let bamRelPath: String
    }
    var rowsToProcess: [RowToProcess] = []
    while sqlite3_step(selectStmt) == SQLITE_ROW {
        let rowid = sqlite3_column_int64(selectStmt, 0)
        guard let sPtr = sqlite3_column_text(selectStmt, 1),
              let aPtr = sqlite3_column_text(selectStmt, 2),
              let bPtr = sqlite3_column_text(selectStmt, 3) else { continue }
        rowsToProcess.append(RowToProcess(
            rowid: rowid,
            sample: String(cString: sPtr),
            accession: String(cString: aPtr),
            bamRelPath: String(cString: bPtr)
        ))
    }

    guard !rowsToProcess.isEmpty else {
        if !quiet { print("  No rows with BAM paths found, skipping unique reads") }
        return
    }

    // Step 1: Run markdup on each unique BAM file
    let uniqueBAMPaths = Set(rowsToProcess.map { bamPathResolver(resultURL, $0.sample, $0.bamRelPath) })
    if !quiet { print("Running markdup on \(uniqueBAMPaths.count) BAM file(s)...") }
    var marked = 0
    for bamFullPath in uniqueBAMPaths {
        let bamURL = URL(fileURLWithPath: bamFullPath)
        guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
        do {
            let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
            if !result.wasAlreadyMarkduped { marked += 1 }
        } catch {
            if !quiet { print("  Warning: markdup failed on \(bamURL.lastPathComponent): \(error.localizedDescription)") }
        }
    }
    if !quiet && marked > 0 { print("  Marked duplicates in \(marked) BAM file(s)") }

    // Step 2: Count reads_aligned and unique_reads per (sample, accession)
    if !quiet { print("Counting reads per organism...") }

    // Build accession_length map from samtools idxstats if needed
    var refLengths: [String: Int] = [:]
    if updateAccessionLength {
        for bamFullPath in uniqueBAMPaths {
            guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
            let idxProcess = Process()
            idxProcess.executableURL = URL(fileURLWithPath: samtoolsPath)
            idxProcess.arguments = ["idxstats", bamFullPath]
            let pipe = Pipe()
            idxProcess.standardOutput = pipe
            idxProcess.standardError = FileHandle.nullDevice
            do { try idxProcess.run() } catch { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            idxProcess.waitUntilExit()
            guard idxProcess.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { continue }
            for line in output.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 2 else { continue }
                let refName = String(cols[0])
                guard refName != "*" else { continue }
                if let len = Int(cols[1]), len > 0 {
                    refLengths[refName] = len
                }
            }
        }
    }

    // Update accession_length column (TaxTriage only)
    if updateAccessionLength && !refLengths.isEmpty {
        let lenSQL = "UPDATE \(table) SET accession_length = ? WHERE rowid = ?"
        var lenStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, lenSQL, -1, &lenStmt, nil) == SQLITE_OK {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            var lenUpdated = 0
            for row in rowsToProcess {
                if let len = refLengths[row.accession] {
                    sqlite3_reset(lenStmt)
                    sqlite3_bind_int64(lenStmt, 1, Int64(len))
                    sqlite3_bind_int64(lenStmt, 2, row.rowid)
                    sqlite3_step(lenStmt)
                    lenUpdated += 1
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_finalize(lenStmt)
            if !quiet && lenUpdated > 0 { print("  Updated accession lengths for \(lenUpdated) organisms") }
        }
    }

    // Update unique_reads via markdup-based counts
    let uniqueSQL = "UPDATE \(table) SET unique_reads = ? WHERE rowid = ?"
    var uniqueStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, uniqueSQL, -1, &uniqueStmt, nil) == SQLITE_OK else {
        if !quiet { print("Warning: failed to prepare UPDATE for unique reads") }
        return
    }
    defer { sqlite3_finalize(uniqueStmt) }

    sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
    var updated = 0
    // Cache: avoid recounting for same BAM+accession
    var cache: [String: Int] = [:]
    for (i, row) in rowsToProcess.enumerated() {
        let bamFullPath = bamPathResolver(resultURL, row.sample, row.bamRelPath)
        guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }

        let cacheKey = "\(bamFullPath)\t\(row.accession)"
        let unique: Int
        if let cached = cache[cacheKey] {
            unique = cached
        } else {
            do {
                unique = try MarkdupService.countReads(
                    bamURL: URL(fileURLWithPath: bamFullPath),
                    accession: row.accession,
                    flagFilter: 0x404,  // unmapped + duplicate
                    samtoolsPath: samtoolsPath
                )
                cache[cacheKey] = unique
            } catch {
                continue
            }
        }

        sqlite3_reset(uniqueStmt)
        sqlite3_bind_int64(uniqueStmt, 1, Int64(unique))
        sqlite3_bind_int64(uniqueStmt, 2, row.rowid)
        sqlite3_step(uniqueStmt)
        updated += 1

        if (i + 1) % 50 == 0 && !quiet {
            print("  Processed \(i + 1)/\(rowsToProcess.count) organisms...")
        }
    }
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
    if !quiet { print("  Updated unique reads for \(updated)/\(rowsToProcess.count) organisms") }
}
```

- [ ] **Step 2: Delete the now-unused computeUniqueReads and cigarConsumedBases helpers**

In `Sources/LungfishCLI/Commands/BuildDbCommand.swift`, find:
- `private func computeUniqueReads(samtoolsPath: String, bamPath: String, accession: String) -> Int?`
- `private func cigarConsumedBases(_ cigar: String) -> Int`

Delete both functions entirely. They are replaced by `MarkdupService.countReads()`.

- [ ] **Step 3: Build and run existing tests**

Run: `swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test --filter BuildDbCommandTests`
Expected: All existing tests pass. Counts may differ slightly from the old heuristic — update any assertion that checks exact unique_reads values if needed (the test fixtures have small data so duplicate counts should be deterministic).

- [ ] **Step 4: Write BuildDbCommandMarkdupTests**

```swift
// BuildDbCommandMarkdupTests.swift - Tests that build-db uses markdup pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandMarkdupTests: XCTestCase {

    private var samtoolsPath: String {
        BamFixtureBuilder.locateSamtools() ?? ""
    }

    private func findFixtureDir(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        fatalError("Could not find fixture: \(name)")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbMarkdupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// build-db taxtriage should run markdup on all BAMs in the result directory.
    func testBuildDbTaxTriageRunsMarkdup() async throws {
        guard !samtoolsPath.isEmpty else {
            XCTFail("samtools not available")
            return
        }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fixture = findFixtureDir("taxtriage-mini")
        let resultDir = tmp.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixture, to: resultDir)

        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify every BAM in minimap2/ has been marked
        let minimap2Dir = resultDir.appendingPathComponent("minimap2")
        let contents = try FileManager.default.contentsOfDirectory(at: minimap2Dir, includingPropertiesForKeys: nil)
        let bams = contents.filter { $0.pathExtension == "bam" }
        XCTAssertGreaterThan(bams.count, 0, "Fixture must have BAM files")
        for bam in bams {
            XCTAssertTrue(
                MarkdupService.isAlreadyMarkduped(bamURL: bam, samtoolsPath: samtoolsPath),
                "BAM \(bam.lastPathComponent) should have been marked by build-db"
            )
        }

        // Verify unique_reads values in DB are consistent with samtools view -c -F 0x404
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        let allRows = try db.fetchRows(samples: samples.map(\.sample))
        let rowsWithBAM = allRows.filter { $0.bamPath != nil && $0.primaryAccession != nil && $0.uniqueReads != nil }
        XCTAssertGreaterThan(rowsWithBAM.count, 0, "At least some rows should have unique reads populated")

        if let row = rowsWithBAM.first {
            let bamURL = resultDir.appendingPathComponent(row.bamPath!)
            let expected = try MarkdupService.countReads(
                bamURL: bamURL,
                accession: row.primaryAccession!,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath
            )
            XCTAssertEqual(row.uniqueReads, expected, "DB unique_reads must match samtools count")
        }
    }
}
```

- [ ] **Step 5: Run the new test**

Run: `swift test --filter BuildDbCommandMarkdupTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/BuildDbCommand.swift \
      Tests/LungfishCLITests/BuildDbCommandMarkdupTests.swift
git commit -m "feat: BuildDbCommand uses MarkdupService for unique read counts"
```

---

## Task 8: NVD Database Schema Migration

Add `unique_reads INTEGER` column to the `blast_hits` table. Schema migration on read (ALTER TABLE ADD COLUMN) ensures backward compatibility with existing NVD databases.

**Files:**
- Modify: `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift` — schema, migration, insert, struct

- [ ] **Step 1: Add `uniqueReads` field to NvdBlastHit struct**

Find the `public struct NvdBlastHit` definition in `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift`. Add `uniqueReads: Int?` after `mappedReads`:

```swift
public struct NvdBlastHit: Sendable {
    // ... existing fields ...
    public let mappedReads: Int
    public let uniqueReads: Int?   // NEW — populated post-markdup, nullable for backward compat
    public let totalReads: Int
    // ... rest of fields ...
}
```

Add the parameter to the `public init`:
```swift
public init(
    // ... existing ...
    mappedReads: Int,
    uniqueReads: Int? = nil,   // NEW
    totalReads: Int,
    // ...
)
```

- [ ] **Step 2: Update `createSchema` to include `unique_reads`**

Find `createSchema` and add `unique_reads INTEGER` to the `blast_hits` CREATE TABLE:

```swift
CREATE TABLE blast_hits (
    rowid INTEGER PRIMARY KEY,
    // ... existing columns ...
    mapped_reads INTEGER NOT NULL,
    unique_reads INTEGER,             -- NEW — nullable until markdup populates
    total_reads INTEGER NOT NULL,
    // ... rest of columns ...
);
```

- [ ] **Step 3: Add schema migration on read-only open**

In `public init(at url: URL) throws` (the read-only open), after `sqlite3_open_v2` succeeds but before the pragmas, add:

```swift
// Schema migration: ensure unique_reads column exists (added post-initial release)
let colCheck = "PRAGMA table_info(blast_hits)"
var checkStmt: OpaquePointer?
var hasUniqueReads = false
if sqlite3_prepare_v2(db, colCheck, -1, &checkStmt, nil) == SQLITE_OK {
    while sqlite3_step(checkStmt) == SQLITE_ROW {
        if let namePtr = sqlite3_column_text(checkStmt, 1) {
            let colName = String(cString: namePtr)
            if colName == "unique_reads" {
                hasUniqueReads = true
                break
            }
        }
    }
    sqlite3_finalize(checkStmt)
}
if !hasUniqueReads {
    // Reopen read-write briefly to add the column
    sqlite3_close(db)
    var rwDB: OpaquePointer?
    if sqlite3_open_v2(url.path, &rwDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
        sqlite3_exec(rwDB, "ALTER TABLE blast_hits ADD COLUMN unique_reads INTEGER", nil, nil, nil)
        sqlite3_close(rwDB)
    }
    // Reopen read-only
    let rc2 = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard rc2 == SQLITE_OK else {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
        sqlite3_close(db)
        db = nil
        throw NvdDatabaseError.openFailed(msg)
    }
}
```

- [ ] **Step 4: Update `bulkInsertHits` INSERT SQL**

Find `bulkInsertHits`. Update the INSERT SQL to include `unique_reads`:

```swift
let insertSQL = """
INSERT INTO blast_hits (
    experiment, blast_task, sample_id, qseqid, qlen,
    sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
    sscinames, staxids, blast_db_version, snakemake_run_id,
    mapped_reads, unique_reads, total_reads, stat_db_version,
    adjusted_taxid, adjustment_method, adjusted_taxid_name,
    adjusted_taxid_rank, hit_rank, reads_per_billion
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
"""
```

(That's 26 placeholders — count carefully, adding one for `unique_reads`.)

Update the bindings in the loop: after the `mapped_reads` bind, add a `unique_reads` bind (nullable):

```swift
// ... existing bindings up to mapped_reads ...
sqlite3_bind_int64(stmt, 17, Int64(hit.mappedReads))
// NEW: bind 18 = unique_reads (nullable)
if let unique = hit.uniqueReads {
    sqlite3_bind_int64(stmt, 18, Int64(unique))
} else {
    sqlite3_bind_null(stmt, 18)
}
sqlite3_bind_int64(stmt, 19, Int64(hit.totalReads))
// ... shift all subsequent binding indices by +1 ...
```

**IMPORTANT:** Every binding index after position 17 must shift by +1. If the existing code had `sqlite3_bind_int64(stmt, 18, Int64(hit.totalReads))`, it becomes `stmt, 19`. Read the surrounding code carefully and update every index.

- [ ] **Step 5: Update the SELECT in `collectRows` (the read side)**

Find `collectRows` (or wherever SELECT * FROM blast_hits is parsed into NvdBlastHit). Add `unique_reads` reading:

```swift
let mappedReads = Int(sqlite3_column_int64(stmt, N))    // existing
let uniqueReads: Int? = sqlite3_column_type(stmt, N+1) == SQLITE_NULL
    ? nil : Int(sqlite3_column_int64(stmt, N+1))
let totalReads = Int(sqlite3_column_int64(stmt, N+2))
```

Replace `N`, `N+1`, `N+2` with the actual column indices. Look at the existing `collectRows` function — it hard-codes column positions. You'll need to shift every position after `mapped_reads` by +1.

- [ ] **Step 6: Build and run existing tests**

Run: `swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test --filter NvdDatabaseTests`
Expected: All existing tests pass. Any test that constructs an `NvdBlastHit` without specifying `uniqueReads` should still work since it has a default value of `nil`.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift
git commit -m "feat: add unique_reads column to NVD database schema (nullable, migrated)"
```

---

## Task 9: NVD Import Pipeline — Run Markdup and Populate Unique Reads

Hook `MarkdupService.markdup()` into NVD import and populate `unique_reads` per blast hit row.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/NvdCommand.swift` — add markdup step after BAM staging

- [ ] **Step 1: Read NvdCommand.swift to locate the BAM staging step**

Run: `grep -n "bam_path\|bamPath\|NvdDatabase.create" Sources/LungfishCLI/Commands/NvdCommand.swift | head -20`

Note the line where `NvdDatabase.create(at:hits:samples:)` is called. The markdup step goes AFTER that call.

- [ ] **Step 2: Add markdup step after NvdDatabase.create**

Immediately after the line that calls `NvdDatabase.create(at:hits:samples:)`, add:

```swift
// Run markdup on all BAMs referenced by samples, then update unique_reads per hit.
if let samtoolsPath = locateSamtools() {
    let bamURLs = Set(samples.compactMap { sample -> URL? in
        let url = URL(fileURLWithPath: sample.bamPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    })
    for bamURL in bamURLs {
        _ = try? MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
    }

    // Update blast_hits.unique_reads via samtools view -c -F 0x404 per (bam, sseqid)
    var db: OpaquePointer?
    if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
        defer { sqlite3_close(db) }

        // Build sample_id → bam_path map
        var bamPathBySample: [String: String] = [:]
        for sample in samples {
            bamPathBySample[sample.sampleId] = sample.bamPath
        }

        let updateSQL = "UPDATE blast_hits SET unique_reads = ? WHERE rowid = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }

            let selectSQL = "SELECT rowid, sample_id, sseqid FROM blast_hits"
            var selectStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(selectStmt) }

                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
                var cache: [String: Int] = [:]
                var updated = 0
                while sqlite3_step(selectStmt) == SQLITE_ROW {
                    let rowid = sqlite3_column_int64(selectStmt, 0)
                    guard let sPtr = sqlite3_column_text(selectStmt, 1),
                          let sseqPtr = sqlite3_column_text(selectStmt, 2) else { continue }
                    let sampleId = String(cString: sPtr)
                    let sseqid = String(cString: sseqPtr)
                    guard let bamPath = bamPathBySample[sampleId],
                          FileManager.default.fileExists(atPath: bamPath) else { continue }

                    let cacheKey = "\(bamPath)\t\(sseqid)"
                    let unique: Int
                    if let cached = cache[cacheKey] {
                        unique = cached
                    } else {
                        do {
                            unique = try MarkdupService.countReads(
                                bamURL: URL(fileURLWithPath: bamPath),
                                accession: sseqid,
                                flagFilter: 0x404,
                                samtoolsPath: samtoolsPath
                            )
                            cache[cacheKey] = unique
                        } catch {
                            continue
                        }
                    }

                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, Int64(unique))
                    sqlite3_bind_int64(stmt, 2, rowid)
                    sqlite3_step(stmt)
                    updated += 1
                }
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                if !globalOptions.quiet {
                    print("Updated unique_reads for \(updated) NVD hits")
                }
            }
        }
    }
}
```

Add `locateSamtools()` as a private method at the end of the NvdCommand struct if it doesn't already exist:

```swift
private func locateSamtools() -> String? {
    let candidates = [
        "/opt/homebrew/Cellar/samtools/1.23/bin/samtools",
        "/opt/homebrew/bin/samtools",
        "/usr/local/bin/samtools",
        "/usr/bin/samtools",
    ]
    for p in candidates {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}
```

Add `import LungfishIO` at the top of the file if not already imported (`MarkdupService` lives in LungfishIO).

Add `import SQLite3` at the top if the raw sqlite3 calls aren't already imported.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/NvdCommand.swift
git commit -m "feat: NVD import runs markdup and populates unique_reads"
```

---

## Task 10: NaoMgsBamMaterializer Service

Create the service that synthesizes real BAM files from NAO-MGS SQLite data.

**Files:**
- Create: `Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift`
- Create: `Tests/LungfishIOTests/NaoMgsBamMaterializerTests.swift`

- [ ] **Step 1: Create NaoMgsBamMaterializer.swift**

```swift
// NaoMgsBamMaterializer.swift - Generates BAM files from NAO-MGS SQLite rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "NaoMgsBamMaterializer")

/// Generates real BAM files from NAO-MGS SQLite virus_hits rows so the
/// miniBAM viewer can use the standard `displayContig(bamURL:...)` code path
/// and benefit from samtools markdup PCR duplicate detection.
///
/// Output location: `<resultURL>/bams/<sample>.bam` (+ `.bai` index)
public enum NaoMgsBamMaterializer {

    /// Materializes BAM files for every sample in a NAO-MGS result directory.
    ///
    /// Idempotent: skips samples whose BAM already exists and is already markdup'd.
    /// After generation, runs MarkdupService.markdup() on each BAM.
    ///
    /// - Parameters:
    ///   - dbPath: Path to the NAO-MGS SQLite database.
    ///   - resultURL: Result directory (BAMs written to `<resultURL>/bams/`).
    ///   - samtoolsPath: Path to samtools binary.
    ///   - force: Regenerate BAMs even if they already exist.
    /// - Returns: URLs of generated (or existing) BAM files.
    public static func materializeAll(
        dbPath: String,
        resultURL: URL,
        samtoolsPath: String,
        force: Bool = false
    ) throws -> [URL] {
        let fm = FileManager.default
        let bamsDir = resultURL.appendingPathComponent("bams")
        try fm.createDirectory(at: bamsDir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open NAO-MGS database at \(dbPath)"])
        }
        defer { sqlite3_close(db) }

        // 1. Fetch all distinct samples
        let samples = try fetchSamples(db: db)

        // 2. Fetch all reference lengths (shared across samples)
        let allRefLengths = try fetchReferenceLengths(db: db)

        var generated: [URL] = []
        for sample in samples {
            let bamURL = bamsDir.appendingPathComponent("\(sample).bam")

            if !force && fm.fileExists(atPath: bamURL.path) {
                // Already generated; ensure markdup has been run
                _ = try? MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
                generated.append(bamURL)
                continue
            }

            try generateBam(
                db: db,
                sample: sample,
                refLengths: allRefLengths,
                bamURL: bamURL,
                samtoolsPath: samtoolsPath
            )
            _ = try? MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
            generated.append(bamURL)

            logger.info("Materialized NAO-MGS BAM for sample \(sample, privacy: .public)")
        }

        return generated
    }

    // MARK: - Private

    private static func fetchSamples(db: OpaquePointer?) throws -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT sample FROM virus_hits ORDER BY sample"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare sample query"])
        }
        defer { sqlite3_finalize(stmt) }
        var samples: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                samples.append(String(cString: ptr))
            }
        }
        return samples
    }

    private static func fetchReferenceLengths(db: OpaquePointer?) throws -> [String: Int] {
        var stmt: OpaquePointer?
        let sql = "SELECT accession, length FROM reference_lengths"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]  // table may not exist in older databases
        }
        defer { sqlite3_finalize(stmt) }
        var map: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let accPtr = sqlite3_column_text(stmt, 0) {
                let acc = String(cString: accPtr)
                let len = Int(sqlite3_column_int64(stmt, 1))
                map[acc] = len
            }
        }
        return map
    }

    /// Synthesizes SAM text for a single sample's virus_hits rows, then pipes
    /// through `samtools view -bS - | samtools sort -o` to produce a sorted BAM.
    private static func generateBam(
        db: OpaquePointer?,
        sample: String,
        refLengths: [String: Int],
        bamURL: URL,
        samtoolsPath: String
    ) throws {
        // 1. Collect accessions used by this sample to build @SQ header lines
        var usedAccessions: Set<String> = []
        var accessionHitCount = 0
        var accStmt: OpaquePointer?
        let accSQL = "SELECT DISTINCT subject_seq_id FROM virus_hits WHERE sample = ?"
        guard sqlite3_prepare_v2(db, accSQL, -1, &accStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare accession query"])
        }
        sample.withCString { cStr in
            sqlite3_bind_text(accStmt, 1, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while sqlite3_step(accStmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(accStmt, 0) {
                usedAccessions.insert(String(cString: ptr))
                accessionHitCount += 1
            }
        }
        sqlite3_finalize(accStmt)

        guard !usedAccessions.isEmpty else {
            logger.warning("No virus_hits for sample \(sample, privacy: .public); skipping BAM generation")
            return
        }

        // 2. Write SAM text: header + alignment lines
        var sam = "@HD\tVN:1.6\tSO:unsorted\n"
        for accession in usedAccessions.sorted() {
            let length = refLengths[accession] ?? 100000  // fallback when reference_lengths missing
            sam += "@SQ\tSN:\(accession)\tLN:\(length)\n"
        }
        sam += "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:1.0\n"

        // 3. Fetch alignment rows and append SAM lines
        var rowStmt: OpaquePointer?
        let rowSQL = """
        SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality, is_reverse_complement
        FROM virus_hits
        WHERE sample = ?
        """
        guard sqlite3_prepare_v2(db, rowSQL, -1, &rowStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare row query"])
        }
        defer { sqlite3_finalize(rowStmt) }
        sample.withCString { cStr in
            sqlite3_bind_text(rowStmt, 1, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        while sqlite3_step(rowStmt) == SQLITE_ROW {
            guard let seqIdPtr = sqlite3_column_text(rowStmt, 0),
                  let subjPtr = sqlite3_column_text(rowStmt, 1),
                  let cigarPtr = sqlite3_column_text(rowStmt, 3),
                  let seqPtr = sqlite3_column_text(rowStmt, 4),
                  let qualPtr = sqlite3_column_text(rowStmt, 5) else { continue }
            let qname = String(cString: seqIdPtr)
            let rname = String(cString: subjPtr)
            let refStart = Int(sqlite3_column_int64(rowStmt, 2))
            let cigar = String(cString: cigarPtr)
            let seq = String(cString: seqPtr)
            let qual = String(cString: qualPtr)
            let isReverse = sqlite3_column_int(rowStmt, 6) != 0
            let flag = isReverse ? 16 : 0
            let pos = refStart + 1  // 0-based to 1-based
            let mapq = 60

            sam += "\(qname)\t\(flag)\t\(rname)\t\(pos)\t\(mapq)\t\(cigar)\t*\t0\t0\t\(seq)\t\(qual)\n"
        }

        // 4. Pipe SAM text through samtools view -bS - | samtools sort -o <bam>
        let cmd = """
        "\(samtoolsPath)" view -bS - | "\(samtoolsPath)" sort -o "\(bamURL.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()

        // Write SAM to the pipe's input handle in a background queue to avoid deadlock
        let samData = sam.data(using: .utf8) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            inPipe.fileHandleForWriting.write(samData)
            try? inPipe.fileHandleForWriting.close()
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "NaoMgsBamMaterializer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "samtools pipeline failed: \(stderr)"])
        }

        // 5. Index the output BAM
        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", bamURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        indexProc.standardError = FileHandle.nullDevice
        try indexProc.run()
        indexProc.waitUntilExit()
        guard indexProc.terminationStatus == 0 else {
            throw NSError(domain: "NaoMgsBamMaterializer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "samtools index failed for \(bamURL.path)"])
        }
    }
}
```

- [ ] **Step 2: Create NaoMgsBamMaterializerTests.swift**

```swift
// NaoMgsBamMaterializerTests.swift - Tests for NaoMgsBamMaterializer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO

final class NaoMgsBamMaterializerTests: XCTestCase {

    private var samtoolsPath: String {
        BamFixtureBuilder.locateSamtools() ?? ""
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsMaterializerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a minimal NAO-MGS SQLite database with one sample and a handful of virus_hits rows.
    private func makeTestDatabase(at dbURL: URL, sample: String = "S1", duplicateCount: Int = 3) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db,
                               SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER NOT NULL,
            cigar TEXT NOT NULL,
            read_sequence TEXT NOT NULL,
            read_quality TEXT NOT NULL,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER NOT NULL,
            query_length INTEGER NOT NULL,
            is_reverse_complement INTEGER NOT NULL,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL NOT NULL
        );
        CREATE TABLE reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL);
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO reference_lengths VALUES ('NC_001', 1000)", nil, nil, nil)

        // Insert `duplicateCount` rows at identical position (will become duplicates after markdup)
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        for i in 0..<duplicateCount {
            let sql = """
            INSERT INTO virus_hits VALUES (
                NULL, '\(sample)', 'read\(i)', 1, 'NC_001', 'Test virus',
                100, '50M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 0,
                'unpaired', 50, 90.0
            )
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func testMaterializeSingleSample() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        XCTAssertEqual(generated.count, 1)
        let bamURL = generated[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path + ".bai"))
    }

    func testMaterializeDuplicatesAreMarked() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 5)

        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: tmp,
            samtoolsPath: samtoolsPath
        )

        let bamURL = generated[0]
        // After markdup, non-duplicate count should be less than total (5)
        let total = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        let nonDup = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(total, 5)
        XCTAssertLessThan(nonDup, total, "Some reads should be flagged as duplicates")
    }

    func testMaterializeIdempotent() throws {
        guard !samtoolsPath.isEmpty else { XCTFail("samtools not available"); return }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "S1", duplicateCount: 3)

        let first = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: first[0].path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        let second = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path, resultURL: tmp, samtoolsPath: samtoolsPath
        )
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: second[0].path)[.modificationDate]) as? Date

        XCTAssertEqual(firstMtime, secondMtime, "Second call should be a no-op")
    }
}
```

- [ ] **Step 3: Build and run tests**

Run: `swift test --filter NaoMgsBamMaterializerTests`
Expected: All 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift \
      Tests/LungfishIOTests/NaoMgsBamMaterializerTests.swift
git commit -m "feat: add NaoMgsBamMaterializer to generate BAMs from SQLite rows"
```

---

## Task 11: NAO-MGS Import Integration

Wire `NaoMgsBamMaterializer.materializeAll()` into the NAO-MGS import CLI flow.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/NaoMgsCommand.swift`

- [ ] **Step 1: Find the NAO-MGS import end-of-pipeline**

Run: `grep -n "NaoMgsDatabase.create\|materializeAll" Sources/LungfishCLI/Commands/NaoMgsCommand.swift | head -5`

Note the line where `NaoMgsDatabase.create(...)` is called. The materialization step goes AFTER.

- [ ] **Step 2: Add materialize call**

After the `NaoMgsDatabase.create(...)` call, add:

```swift
// Materialize BAMs from SQLite rows so the miniBAM viewer can use the
// same displayContig() path as TaxTriage/EsViritu/NVD. Runs markdup automatically.
if let samtoolsPath = locateSamtools() {
    do {
        let generated = try NaoMgsBamMaterializer.materializeAll(
            dbPath: dbURL.path,
            resultURL: resultURL,
            samtoolsPath: samtoolsPath
        )
        if !globalOptions.quiet {
            print("Materialized \(generated.count) BAM file(s) for NAO-MGS samples")
        }
    } catch {
        if !globalOptions.quiet {
            print("Warning: BAM materialization failed: \(error.localizedDescription)")
        }
    }
}
```

If `locateSamtools()` isn't already defined in this file, add it as a private method (see Task 9 Step 2 for the implementation).

Add `import LungfishIO` at the top if not already present.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCLI/Commands/NaoMgsCommand.swift
git commit -m "feat: NAO-MGS import materializes BAMs and runs markdup"
```

---

## Task 12: MarkdupCommand Handles NAO-MGS Result Directories

Extend `lungfish-cli markdup` to detect NAO-MGS result directories and run the materializer before walking BAMs.

**Files:**
- Modify: `Sources/LungfishCLI/Commands/MarkdupCommand.swift`

- [ ] **Step 1: Detect NAO-MGS result dir and materialize first**

Find the `run()` method of `MarkdupCommand`. After checking `isDir.boolValue` but before calling `MarkdupService.markdupDirectory`, add:

```swift
if isDir.boolValue {
    // If this is a NAO-MGS result directory, materialize BAMs from SQLite first
    let naoMgsDbURL = inputURL.appendingPathComponent("naomgs.sqlite")
    if fm.fileExists(atPath: naoMgsDbURL.path) {
        if !globalOptions.quiet {
            print("Detected NAO-MGS result directory; materializing BAMs...")
        }
        _ = try NaoMgsBamMaterializer.materializeAll(
            dbPath: naoMgsDbURL.path,
            resultURL: inputURL,
            samtoolsPath: samtoolsPath,
            force: force
        )
    }

    // ... existing markdupDirectory call ...
}
```

`NaoMgsBamMaterializer` already runs markdup internally, but running `markdupDirectory` again is idempotent and covers the case where other BAMs exist in the tree alongside the NAO-MGS BAMs.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishCLI/Commands/MarkdupCommand.swift
git commit -m "feat: lungfish-cli markdup materializes NAO-MGS BAMs before walking"
```

---

## Task 13: MiniBAMViewController Cleanup

Delete the Swift-side duplicate detection from the viewer and switch to samtools-filtered fetches.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`

- [ ] **Step 1: Delete the Swift-side dedup helpers**

In `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`, find and delete:

- `private func detectDuplicates(in reads: [AlignedRead]) -> Set<Int>` — the entire function
- `private var allDuplicateIndices: Set<Int>` — the stored property
- `private var pcrDuplicateReadCount: Int` — the stored property
- `private func applyDuplicateVisibility(rebuildReference: Bool)` — the visibility toggle function
- Any UI outlet that toggles "show/hide duplicates" (search for `duplicateToggle`, `hideDuplicates`, or similar — delete the checkbox/button declarations, target-action handlers, and setup code)

- [ ] **Step 2: Change fetchReads to exclude duplicates**

Find `displayContig(bamURL:contig:contigLength:indexURL:referenceSequence:maxReads:)`. Inside it, find the call to `provider.fetchReads(...)`. The current call probably uses the default `excludeFlags` value (0x904 = unmapped + secondary + supplementary). Add an explicit parameter to exclude duplicates:

```swift
let fetchedReads = try await provider.fetchReads(
    chromosome: contig,
    start: 0,
    end: contigLength,
    excludeFlags: 0x904 | 0x400,  // also exclude duplicates (0x400)
    maxReads: maxReads
)
```

If `fetchReads` doesn't already have an `excludeFlags` parameter, add one with default `0x904` in its signature, and update the few existing callers.

- [ ] **Step 3: Update code that used `allDuplicateIndices` / `pcrDuplicateReadCount`**

Search the file for remaining references to `allDuplicateIndices` and `pcrDuplicateReadCount`. Delete the lines that read them (status label updates, scroll offset calculations, etc.). Replace status label strings like "N reads (M duplicates)" with just "N reads".

Also remove any reference to `cached.duplicateIndices` in the cache hit path — the cache doesn't need to store duplicate indices anymore because the reads are already filtered. Change the `ContigCacheEntry` struct (likely defined in the same file) to drop the `duplicateIndices` field.

- [ ] **Step 4: Build and fix any remaining compile errors**

Run: `swift build 2>&1 | tail -20`

The compiler will flag every remaining reference. Fix them by:
- Removing the line if it was only used for duplicate visibility
- Replacing `allDuplicateIndices.contains(i)` checks with `false` (no duplicates in the fetched set)
- Updating any test that constructed `MiniBAMViewController` and expected duplicate-related state

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift
git commit -m "refactor: MiniBAMViewController filters duplicates via samtools, deletes Swift-side dedup"
```

---

## Task 14: NaoMgsResultViewController Uses displayContig

Switch NAO-MGS from `displayReads(reads:contig:contigLength:)` to `displayContig(bamURL:contig:contigLength:indexURL:)` so it uses the same BAM-based code path as the other tools.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`

- [ ] **Step 1: Find the displayReads call site**

Run: `grep -n "displayReads" Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`

Expected: one or more calls around line 999 (from earlier exploration).

- [ ] **Step 2: Replace displayReads with displayContig**

At the call site that currently looks like:

```swift
let reads = try database.fetchReadsForAccession(
    sample: sample,
    taxId: taxId,
    accession: summary.accession,
    maxReads: max(1, summary.readCount)
)
self.miniBAMControllers[index].displayReads(
    reads: reads,
    contig: summary.accession,
    contigLength: max(summary.referenceLength, 1)
)
```

Replace with:

```swift
// BAM is materialized at <resultURL>/bams/<sample>.bam
let bamURL = self.resultURL
    .appendingPathComponent("bams")
    .appendingPathComponent("\(sample).bam")
if FileManager.default.fileExists(atPath: bamURL.path) {
    self.miniBAMControllers[index].displayContig(
        bamURL: bamURL,
        contig: summary.accession,
        contigLength: max(summary.referenceLength, 1)
    )
} else {
    // Fallback: materialize on-demand for old result directories that predate
    // the BAM materializer feature.
    Task.detached {
        if let samtoolsPath = Self.locateSamtools() {
            _ = try? NaoMgsBamMaterializer.materializeAll(
                dbPath: database.databaseURL.path,
                resultURL: self.resultURL,
                samtoolsPath: samtoolsPath
            )
        }
        await MainActor.run {
            if FileManager.default.fileExists(atPath: bamURL.path) {
                self.miniBAMControllers[index].displayContig(
                    bamURL: bamURL,
                    contig: summary.accession,
                    contigLength: max(summary.referenceLength, 1)
                )
            }
        }
    }
}
```

Add `import LungfishIO` to the top of the file if not already present.

Add a static `locateSamtools()` helper (or use whatever pattern the rest of the file uses to find samtools).

**Prerequisite property access:**

Before making the displayReads → displayContig swap, verify these properties exist on `NaoMgsResultViewController` and `NaoMgsDatabase`. Add them if missing:

Run these greps:
```bash
grep -n "var resultURL\|resultURL:" Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift
grep -n "var databaseURL\|public var databaseURL" Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift
```

If `NaoMgsResultViewController` lacks a `resultURL` stored property, add:
```swift
private(set) var resultURL: URL = URL(fileURLWithPath: "/")
```
and set it inside the `configure(...)` method that accepts the result URL.

If `NaoMgsDatabase` lacks `databaseURL: URL`, add it following the same pattern as `TaxTriageDatabase`:
```swift
public var databaseURL: URL { url }
```
(where `url` is the existing `private let url: URL` set in `init(at:)`).

- [ ] **Step 3: Build and fix any compile errors**

Run: `swift build 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift
git commit -m "refactor: NAO-MGS viewer uses displayContig with materialized BAMs"
```

---

## Task 15: Delete MiniBAMViewController.displayReads

Once the NAO-MGS viewer is migrated, the `displayReads(reads:contig:contigLength:)` entry point is no longer called by anything. Delete it.

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`

- [ ] **Step 1: Verify no remaining callers**

Run: `grep -rn "\.displayReads(reads:" Sources/`
Expected: zero matches.

- [ ] **Step 2: Delete the method**

Find `public func displayReads(reads: [AlignedRead], contig: String, contigLength: Int)` in `MiniBAMViewController.swift` and delete the entire function body.

- [ ] **Step 3: Delete any helpers only used by displayReads**

The compiler will flag orphaned helpers. Delete any that become unreachable.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift
git commit -m "refactor: remove MiniBAMViewController.displayReads (unused after NAO-MGS migration)"
```

---

## Task 16: Rebuild Real Databases and Manual Verification

Rebuild the classifier DBs against real data and verify end-to-end behavior.

**No file changes.**

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 2: Rebuild TaxTriage DB with markdup-backed counts**

```bash
.build/debug/lungfish-cli build-db taxtriage \
  "/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18" \
  --force
```

Expected output includes:
- `Running markdup on N BAM file(s)...`
- `  Marked duplicates in M BAM file(s)`
- `Counting reads per organism...`
- `  Updated unique reads for K/N organisms`

- [ ] **Step 3: Verify markdup-based count for SARS-CoV-2 in SRR35520576**

```bash
sqlite3 /Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18/taxtriage.sqlite \
  "SELECT reads_aligned, unique_reads FROM taxonomy_rows WHERE sample='SRR35520576' AND organism LIKE '%Severe acute%'"
```

Compare against the external samtools check:
```bash
BAM=/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18/minimap2/SRR35520576.SRR35520576.dwnld.references.bam
/opt/homebrew/Cellar/samtools/1.23/bin/samtools view -c -F 0x004 "$BAM" NC_045512.2
/opt/homebrew/Cellar/samtools/1.23/bin/samtools view -c -F 0x404 "$BAM" NC_045512.2
```

Expected: DB values match samtools output exactly. The unique count should be significantly less than the aligned count (high duplication rate in this dataset).

- [ ] **Step 4: Verify BAM has markdup header**

```bash
/opt/homebrew/Cellar/samtools/1.23/bin/samtools view -H \
  /Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/taxtriage-2026-04-06T20-46-18/minimap2/SRR35520576.SRR35520576.dwnld.references.bam \
  | grep "samtools.markdup"
```

Expected: one or more `@PG ID:samtools.markdup` lines.

- [ ] **Step 5: Launch app and manually verify GUI**

1. Open a TaxTriage result → batch flat table loads with unique reads column populated
2. Click an organism row → miniBAM pane shows reads, duplicates are NOT displayed (no greyed-out toggle present)
3. Open an NVD result → contig table has "Unique Reads" column
4. Open a NAO-MGS result → miniBAM displays from the generated BAM file at `<result>/bams/<sample>.bam`
5. Delete a BAM index (`rm <bam>.bai`) then re-open the result → the viewer either regenerates the index or logs a clear error

- [ ] **Step 6: Commit verification**

```bash
git commit --allow-empty -m "verify: markdup service integration complete"
```
