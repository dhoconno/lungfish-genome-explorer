// FASTQIngestionInterleaveCompressPinTests.swift - The compressor spawn of the paired FASTQ import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// `FASTQIngestionPipeline.interleaveAndCompress` interleaves R1 and R2 in Swift and pipes the stream through the
/// managed bgzip or pigz, with the output and the stderr log written straight to files (Phase 2.13 lane 13.10 M3
/// item 3). The pipeline takes its tools from the managed set, so these pins use the real compressor and skip when
/// neither is installed. They hold at the base, where the spawn was a raw `Process` with a raw terminate, and after
/// it runs on `ToolProcess`. Each import is large enough to cross the pipe buffer and the interleaver's 4 MiB flush.
final class FASTQIngestionInterleaveCompressPinTests: XCTestCase {
    private var root: URL!
    private var importsDir: URL!
    private let pairCount = 25_000
    private let quality = String(repeating: "I", count: 100)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQ Interleave Pin \(UUID().uuidString)", isDirectory: true)
        importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    private func bases(mate: Int) -> String {
        String(repeating: mate == 1 ? "ACGT" : "TGCA", count: 25)
    }

    private func recordText(_ index: Int, mate: Int) -> String {
        "@pair\(index)/\(mate)\n\(bases(mate: mate))\n+\n\(quality)\n"
    }

    private func writePairs(r2Count: Int) throws -> (r1: URL, r2: URL) {
        var r1Text = ""
        var r2Text = ""
        r1Text.reserveCapacity(pairCount * 230)
        r2Text.reserveCapacity(pairCount * 230)
        for index in 1...pairCount { r1Text += recordText(index, mate: 1) }
        for index in 1...r2Count { r2Text += recordText(index, mate: 2) }
        let r1 = root.appendingPathComponent("Sample_R1.fastq")
        let r2 = root.appendingPathComponent("Sample_R2.fastq")
        try Data(r1Text.utf8).write(to: r1)
        try Data(r2Text.utf8).write(to: r2)
        return (r1, r2)
    }

    private func config(_ inputs: (r1: URL, r2: URL)) -> FASTQIngestionConfig {
        FASTQIngestionConfig(
            inputFiles: [inputs.r1, inputs.r2],
            pairingMode: .pairedEnd,
            outputDirectory: importsDir,
            threads: 1,
            deleteOriginals: true,
            qualityBinning: .none,
            clumpingTool: .none
        )
    }

    /// Nothing but the finished output may sit in the imports folder, and no hidden stage or stderr log.
    private func assertNoScratchFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: importsDir.path)
        for name in names {
            XCTAssertFalse(name.hasPrefix("."), "hidden scratch file \(name)", file: file, line: line)
            XCTAssertFalse(name.hasSuffix(".tmp") || name.hasSuffix(".stderr"), "scratch file \(name)", file: file, line: line)
        }
    }

    func testTheOutputDecompressesToTheInterleavedRecordsInOrderAndLeavesNoScratchFiles() async throws {
        try await requireCompressor()
        let inputs = try writePairs(r2Count: pairCount)
        let result = try await FASTQIngestionPipeline().run(config: config(inputs), progress: { _, _ in })

        let output = importsDir.appendingPathComponent("Sample.fastq.gz")
        XCTAssertEqual(result.outputFile.standardizedFileURL, output.standardizedFileURL)
        XCTAssertTrue(["bgzip", "pigz"].contains(result.processingTool ?? ""), "\(result.processingTool ?? "nil")")
        var lines: [String] = []
        lines.reserveCapacity(pairCount * 8)
        try output.forEachLineAutoDecompressing { lines.append($0) }
        var expected: [String] = []
        expected.reserveCapacity(pairCount * 8)
        for index in 1...pairCount {
            for mate in 1...2 {
                expected += ["@pair\(index)/\(mate)", bases(mate: mate), "+", quality]
            }
        }
        XCTAssertEqual(lines.count, expected.count)
        XCTAssertTrue(lines == expected, "the decompressed output is not the R1 and R2 records alternating in order")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputs.r1.path), "originals are deleted after a good import")
        try assertNoScratchFiles()
    }

    func testAMateCountMismatchAfterMuchOutputThrowsTheInterleaversErrorAndLeavesNothing() async throws {
        try await requireCompressor()
        let inputs = try writePairs(r2Count: pairCount - 1)
        do {
            _ = try await FASTQIngestionPipeline().run(config: config(inputs), progress: { _, _ in })
            XCTFail("a mismatched pair imported")
        } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch {
            // The interleaver's own error reaches the caller, not a compressor failure.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs.r1.path), "R1 survives a failed import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs.r2.path), "R2 survives a failed import")
        XCTAssertFalse(FileManager.default.fileExists(atPath: importsDir.appendingPathComponent("Sample.fastq.gz").path))
        try assertNoScratchFiles()
    }

    func testACancelDuringTheInterleaveEndsInCancellationAndLeavesNothing() async throws {
        try await requireCompressor()
        let inputs = try writePairs(r2Count: pairCount)
        let importConfig = config(inputs)
        let outcome = await Task.detached { () -> Result<Void, Error> in
            do {
                _ = try await FASTQIngestionPipeline().run(config: importConfig, progress: { _, message in
                    if message.hasPrefix("Interleaving paired reads into") {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        guard case .failure(let error) = outcome else {
            XCTFail("a cancelled import finished")
            return
        }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs.r1.path), "R1 survives a cancelled import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs.r2.path), "R2 survives a cancelled import")
        XCTAssertFalse(FileManager.default.fileExists(atPath: importsDir.appendingPathComponent("Sample.fastq.gz").path))
        try assertNoScratchFiles()
    }
}
