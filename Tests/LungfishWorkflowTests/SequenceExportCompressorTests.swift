// SequenceExportCompressorTests.swift - The words of the compressor's refusals and its durability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3, fixes F5 (c) and F5 (d) of review A49-M3. The words of the compressor's errors reach a
// person in the Export Failed alert, and no other test drives them (UX 1). The compressor publishes a part file
// through `DurableReplace`, a new call that the tests of lane S62 do not cover, so the second class has Durability
// in its name, which is what `scripts/testing/exfat-tests.sh --simulate` selects.
//
// Phase 2.13 lane 13.17 M3. zstd is a managed tool of Lungfish, so the durability tests run it from a stand-in in a
// temporary home that follows zstd's command line, and the not-found words point at Lungfish's own setup.

import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SequenceExportCompressorTests: XCTestCase {
    /// The words point at Lungfish's Required Setup, where the tool is installed, and name no package manager
    /// and no place that was searched (lane 13.17 M3, BIO 4).
    func testTheRefusalWordsPointAtLungfishSetupAndNotAtHomebrew() {
        XCTAssertEqual(
            SequenceExportCompressor.CompressionError.compressorNotFound.errorDescription,
            "zstd is not installed. macOS does not ship it, and Lungfish installs it with its Required Setup. "
                + "In the app, open the Welcome window and click Install, or run "
                + "lungfish-cli tools update --apply --yes --required-only. You can also export with gzip."
        )
        XCTAssertEqual(
            SequenceExportCompressor.CompressionError.compressorFailed(exitCode: 2, stderr: "bad\n").errorDescription,
            "zstd failed with exit code 2: bad"
        )
    }
}

/// gzip runs from the system, and zstd runs the managed zstd, here a stand-in in a temporary home, so every test
/// holds on every Mac.
final class SequenceExportCompressorDurabilityTests: XCTestCase {
    private var root: URL!
    private var standIn: ManagedTestStandIn!
    private var runner: NativeToolRunner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceExportCompressorDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        standIn = try ManagedTestStandIn(prefix: "SequenceExportCompressorHome")
        try standIn.install("zstd", script: ManagedTestStandIn.zstdScript)
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: standIn.home, appIdentity: .preview)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        standIn.remove()
    }

    private var kinds: [SequenceExportCompressor.Kind] { SequenceExportCompressor.Kind.allCases }

    func testEachCompressorPublishesAWholeFileThatDecompressesToTheSource() async throws {
        let source = root.appendingPathComponent("export.fa")
        let text = String(repeating: ">a\nACGTACGTAC\n", count: 2_000)
        try text.write(to: source, atomically: true, encoding: .utf8)
        for kind in kinds {
            let destination = root.appendingPathComponent("out.fa.\(kind.fileExtension)")
            try await SequenceExportCompressor.compress(source: source, to: destination, kind: kind, runner: runner)
            XCTAssertEqual(try decompress(destination, kind: kind), text, "\(kind) publishes the whole file")
            XCTAssertEqual(stages(), [], "\(kind) leaves no stage")
        }
    }

    /// The export runs the zstd of the managed environment and says which executable that was, and gzip, which
    /// stays on the system tool, returns no receipt.
    func testZstdRunsTheManagedZstdAndReturnsItsReceipt() async throws {
        let source = root.appendingPathComponent("export.fa")
        try ">a\nACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out.fa.zst")
        let receipt = try await SequenceExportCompressor.compress(
            source: source, to: destination, kind: .zstd, runner: runner
        )
        let written = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        XCTAssertTrue(written.hasPrefix(ManagedTestStandIn.compressedMarker + "\n"), "the managed zstd wrote the file")
        let zstd = try XCTUnwrap(receipt, "zstd returns a receipt")
        XCTAssertEqual(zstd.toolName, "zstd")
        XCTAssertTrue(zstd.executable.path.hasSuffix(".lungfish/conda/envs/zstd/bin/zstd"), zstd.executable.path)
        XCTAssertEqual(zstd.arguments, ["-c", source.path])
        let gzip = try await SequenceExportCompressor.compress(
            source: source, to: root.appendingPathComponent("out.fa.gz"), kind: .gzip, runner: runner
        )
        XCTAssertNil(gzip, "gzip records no managed step")
    }

    /// Without the managed zstd the export refuses in Lungfish's words and publishes nothing.
    func testAMissingManagedZstdRefusesAndPublishesNothing() async throws {
        let emptyHome = try ManagedTestStandIn(prefix: "SequenceExportCompressorEmptyHome")
        defer { emptyHome.remove() }
        let source = root.appendingPathComponent("export.fa")
        try ">a\nACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out.fa.zst")
        do {
            try await SequenceExportCompressor.compress(
                source: source, to: destination, kind: .zstd,
                runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: emptyHome.home, appIdentity: .preview)
            )
            XCTFail("zstd without the managed tool must not publish")
        } catch let error as SequenceExportCompressor.CompressionError {
            XCTAssertEqual(error, .compressorNotFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing is published")
        XCTAssertEqual(stages(), [], "no stage is left")
    }

    func testAFailingCompressorLeavesTheEarlierDestination() async throws {
        let missing = root.appendingPathComponent("missing.fa")
        let destination = root.appendingPathComponent("held.fa.out")
        let earlier = Data("an earlier export".utf8)
        for kind in kinds {
            try earlier.write(to: destination)
            do {
                try await SequenceExportCompressor.compress(source: missing, to: destination, kind: kind, runner: runner)
                XCTFail("\(kind) of a missing file must fail")
            } catch {
            }
            XCTAssertEqual(try Data(contentsOf: destination), earlier, "\(kind) keeps the earlier bytes")
            XCTAssertEqual(stages(), [], "\(kind) leaves no stage")
        }
    }

    func testATaskCancelledBeforeTheCallThrowsCancellationErrorAndPublishesNothing() async throws {
        let source = root.appendingPathComponent("export.fa")
        try ">a\nACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let runner = self.runner!
        for kind in kinds {
            let destination = root.appendingPathComponent("cancelled.\(kind.fileExtension)")
            let task = Task { () -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                try await SequenceExportCompressor.compress(source: source, to: destination, kind: kind, runner: runner)
            }
            do {
                try await task.value
                XCTFail("\(kind) of a cancelled task must not publish")
            } catch is CancellationError {
            } catch {
                XCTFail("\(kind): expected a cancel, got \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "\(kind) publishes nothing")
            XCTAssertEqual(stages(), [], "\(kind) leaves no stage")
        }
    }

    // MARK: - Helpers

    /// The stage files of `DurableReplace` left in the folder.
    private func stages() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains("lungfish-stage-") }
    }

    private func decompress(_ url: URL, kind: SequenceExportCompressor.Kind) throws -> String {
        let tool = kind == .gzip ? URL(fileURLWithPath: "/usr/bin/gzip") : standIn.executableURL("zstd")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool.lastPathComponent) -dc \(url.lastPathComponent)")
        return String(decoding: data, as: UTF8.self)
    }
}
