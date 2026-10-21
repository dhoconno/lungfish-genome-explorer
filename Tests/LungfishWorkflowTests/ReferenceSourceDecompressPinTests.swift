// ReferenceSourceDecompressPinTests.swift - Pin what the reference import's decompress step does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.17. `ReferenceSourcePreparer` decompresses a wrapped reference with the system gzip and bzip2
// and, since M3, with the xz and zstd that Lungfish manages. A gzip and a bzip2 wrapper give the FASTA they hold,
// and an unknown wrapper is refused with the words a person reads. Neither gzip nor bzip2 is managed, so those
// tests run on every Mac. The xz and zstd tests run stand-ins that follow the tools' `-dc` command line from a
// temporary home, so they run on every Mac too. A cancel ends a decompressor that never finishes, and a missing
// managed tool is a failed decompression in Lungfish's own words.

import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ReferenceSourceDecompressPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourceDecompressPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let fasta = ">chr1\nACGTACGTAC\n>chr2\nTTGGCCAATT\n"

    /// Compresses `fasta` with a system tool (`-k` keeps the source) and returns the wrapped file.
    private func wrapped(by tool: String, suffix: String) throws -> URL {
        let plain = root.appendingPathComponent("reference.fa")
        try fasta.write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-kf", plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) wraps the fixture")
        let result = root.appendingPathComponent("reference.fa" + suffix)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), "\(tool) wrote \(result.lastPathComponent)")
        try FileManager.default.removeItem(at: plain)
        return result
    }

    /// A file the stand-in decompressors read: their marker line, then the FASTA.
    private func standInWrapped(suffix: String) throws -> URL {
        let result = root.appendingPathComponent("reference.fa" + suffix)
        try (ManagedTestStandIn.compressedMarker + "\n" + fasta).write(to: result, atomically: true, encoding: .utf8)
        return result
    }

    private func sequenceNames(of source: URL, runner: NativeToolRunner = .shared) async throws -> [String] {
        try await ReferenceSourcePreparer(runner: runner).prepare(
            sourceURL: source,
            bundleName: "Pin",
            tempDirectory: root.appendingPathComponent("working-\(UUID().uuidString)", isDirectory: true)
        ).sequenceNames
    }

    func testAGzipWrapperGivesTheFastaItHolds() async throws {
        let source = try wrapped(by: "/usr/bin/gzip", suffix: ".gz")
        let names = try await sequenceNames(of: source)
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testABzip2WrapperGivesTheFastaItHolds() async throws {
        let source = try wrapped(by: "/usr/bin/bzip2", suffix: ".bz2")
        let names = try await sequenceNames(of: source)
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testACorruptGzipWrapperIsRefusedAsAFailedDecompression() async throws {
        let source = root.appendingPathComponent("broken.fa.gz")
        try Data("this is not gzip data".utf8).write(to: source)
        do {
            _ = try await sequenceNames(of: source)
            XCTFail("a corrupt wrapper must not give a reference")
        } catch let error as ReferenceBundleImportError {
            guard case .decompressionFailed(let detail) = error else {
                return XCTFail("expected a failed decompression, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the failure says why")
        }
    }

    // MARK: - The managed xz and zstd

    func testAnXzWrapperRunsTheManagedXz() async throws {
        let home = try ManagedTestStandIn(prefix: "ReferenceSourceXzHome")
        defer { home.remove() }
        try home.install("xz", script: ManagedTestStandIn.decompressScript)
        let names = try await sequenceNames(
            of: standInWrapped(suffix: ".xz"), runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home.home, appIdentity: .preview)
        )
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testAZstWrapperRunsTheManagedZstd() async throws {
        let home = try ManagedTestStandIn(prefix: "ReferenceSourceZstdHome")
        defer { home.remove() }
        try home.install("zstd", script: ManagedTestStandIn.decompressScript)
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home.home, appIdentity: .preview)
        for suffix in [".zst", ".zstd"] {
            let names = try await sequenceNames(of: standInWrapped(suffix: suffix), runner: runner)
            XCTAssertEqual(names, ["chr1", "chr2"], "a \(suffix) wrapper")
        }
    }

    /// A missing managed tool is a failed decompression whose words name Lungfish's setup and no package manager.
    func testAMissingManagedToolIsAFailedDecompressionInLungfishWords() async throws {
        let emptyHome = try ManagedTestStandIn(prefix: "ReferenceSourceEmptyHome")
        defer { emptyHome.remove() }
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: emptyHome.home, appIdentity: .preview)
        for (suffix, tool) in [(".xz", "xz"), (".zst", "zstd")] {
            do {
                _ = try await sequenceNames(of: standInWrapped(suffix: suffix), runner: runner)
                XCTFail("a \(suffix) wrapper without the managed \(tool) must not give a reference")
            } catch let error as ReferenceBundleImportError {
                guard case .decompressionFailed(let detail) = error else {
                    return XCTFail("expected a failed decompression, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("\(tool) is not installed"), detail)
                XCTAssertTrue(detail.contains("Required Setup"), detail)
                XCTAssertFalse(detail.lowercased().contains("brew"), detail)
            }
        }
    }

    /// A cancel while a managed decompressor runs ends it and throws `CancellationError` at once (A48 M3 review,
    /// Fix 1). The stand-in sleeps for two minutes, so a cancel that did not end it would fail the time bound.
    func testACancelEndsAManagedDecompressorAtOnce() async throws {
        let home = try ManagedTestStandIn(prefix: "ReferenceSourceSleepHome")
        defer { home.remove() }
        try home.install("xz", script: ManagedTestStandIn.sleepingScript)
        let source = try standInWrapped(suffix: ".xz")
        let preparer = ReferenceSourcePreparer(runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home.home, appIdentity: .preview))
        let working = root.appendingPathComponent("working-cancel", isDirectory: true)
        let started = Date()
        let task = Task { try await preparer.prepare(sourceURL: source, bundleName: "Pin", tempDirectory: working) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled decompression must not give a reference")
        } catch is CancellationError {
        } catch {
            XCTFail("expected a cancel, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the cancel ended the child at once")
    }
}
