// SequenceExportCompressorTests.swift - The words of the compressor's refusals and its durability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3, fixes F5 (c) and F5 (d) of review A49-M3. The words of the compressor's errors reach a
// person in the Export Failed alert, and no other test drives them (UX 1). The compressor publishes a part file
// through `DurableReplace`, a new call that the tests of lane S62 do not cover, so the second class has Durability
// in its name, which is what `scripts/testing/exfat-tests.sh --simulate` selects.

import XCTest
@testable import LungfishWorkflow

final class SequenceExportCompressorTests: XCTestCase {
    func testTheRefusalWordsNameWhatToInstallAndWhereItLooked() {
        XCTAssertEqual(
            SequenceExportCompressor.CompressionError.compressorNotFound(searched: ["/a/zstd", "/b/zstd"]).errorDescription,
            "zstd is not installed. macOS does not ship it. Install it with Homebrew (brew install zstd) or export with gzip. "
                + "Looked in /a/zstd, /b/zstd."
        )
        XCTAssertEqual(
            SequenceExportCompressor.CompressionError.compressorFailed(exitCode: 2, stderr: "bad\n").errorDescription,
            "zstd failed with exit code 2: bad"
        )
    }
}

/// gzip always runs, and zstd runs where one is installed in `/usr/bin` or a Homebrew prefix.
final class SequenceExportCompressorDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceExportCompressorDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var kinds: [SequenceExportCompressor.Kind] {
        SequenceExportCompressor.zstdExecutable() == nil ? [.gzip] : [.gzip, .zstd]
    }

    func testEachCompressorPublishesAWholeFileThatDecompressesToTheSource() async throws {
        let source = root.appendingPathComponent("export.fa")
        let text = String(repeating: ">a\nACGTACGTAC\n", count: 2_000)
        try text.write(to: source, atomically: true, encoding: .utf8)
        for kind in kinds {
            let destination = root.appendingPathComponent("out.fa.\(kind.fileExtension)")
            try await SequenceExportCompressor.compress(source: source, to: destination, kind: kind)
            XCTAssertEqual(try decompress(destination, kind: kind), text, "\(kind) publishes the whole file")
            XCTAssertEqual(stages(), [], "\(kind) leaves no stage")
        }
    }

    func testAFailingCompressorLeavesTheEarlierDestination() async throws {
        let missing = root.appendingPathComponent("missing.fa")
        let destination = root.appendingPathComponent("held.fa.out")
        let earlier = Data("an earlier export".utf8)
        for kind in kinds {
            try earlier.write(to: destination)
            do {
                try await SequenceExportCompressor.compress(source: missing, to: destination, kind: kind)
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
        for kind in kinds {
            let destination = root.appendingPathComponent("cancelled.\(kind.fileExtension)")
            let task = Task { () -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                try await SequenceExportCompressor.compress(source: source, to: destination, kind: kind)
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
        let tool = kind == .gzip
            ? URL(fileURLWithPath: "/usr/bin/gzip")
            : try XCTUnwrap(SequenceExportCompressor.zstdExecutable())
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
