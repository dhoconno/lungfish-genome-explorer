// FASTQIngestionLegacyPhred64Tests.swift - An import refuses a Phred+64 file with words that say how to convert it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 3.0 lane BIN, fix round 2 (BIO-BIN-QIN, N2, S1). Every storage step tells BBTools the scores are Phred+33, so
/// an import of a file in the old Phred+64 encoding (Illumina pipeline 1.3 to 1.7) stops before any storage step, and
/// the error's words are what the operation row shows. The guard throws before any tool starts, so every route is a pure
/// test: no binning and no clumping, the reformat route and the clumpify route. Each file is read once as plain text and
/// once as gzip, the form most imports take.
final class FASTQIngestionLegacyPhred64Tests: XCTestCase {
    func testAPhred64FileIsRefusedWithWordsThatSayHowToConvertIt() async throws {
        let root = try TestTempDirectory.make(prefix: "legacy-phred64")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let plain = root.appendingPathComponent("illumina15.fastq")
        try Self.illumina15Records().write(to: plain, atomically: true, encoding: .utf8)
        let gzipped = try Self.gzipped(plain)

        // Fix round 4, SWIFT S3. The guard sits above the storage switch, so every route refuses: no binning and no
        // clumping (no BBTools), the reformat route and the clumpify route. It throws before any tool starts, so none runs.
        let routes: [(name: String, binning: QualityBinningScheme, skipClumpify: Bool)] = [
            ("none", .none, true), ("reformat", .fiveStep, true), ("clumpify", .fiveStep, false),
        ]
        for route in routes {
            for input in [plain, gzipped] {
                let label = "\(route.name) route, \(input.lastPathComponent)"
                let output = root.appendingPathComponent("out-\(route.name)-\(input.pathExtension)", isDirectory: true)
                do {
                    _ = try await FASTQIngestionPipeline().run(
                        config: FASTQIngestionConfig(
                            inputFiles: [input], pairingMode: .singleEnd, outputDirectory: output, threads: 2,
                            deleteOriginals: false, qualityBinning: route.binning, skipClumpify: route.skipClumpify
                        ),
                        progress: { _, _ in }
                    )
                    XCTFail("\(label) was imported although its scores are Phred+64")
                } catch {
                    let words = error.localizedDescription
                    XCTAssertTrue(words.contains("Phred+64"), "\(label): the words name the encoding: \(words)")
                    XCTAssertTrue(words.contains("Phred+33"), "\(label): the words say what LGE stores: \(words)")
                    XCTAssertTrue(
                        words.contains("reformat.sh qin=64 qout=33"), "\(label): the words say how to convert the file: \(words)"
                    )
                }
            }
        }
    }

    /// Fix round 4, BIO SF1a. ONT chunk binning calls `binQualities`, which launches `reformat.sh` with `qin=33` and
    /// never passes `run`, so it checks the file itself. The refusal comes before any tool starts, so no output exists.
    func testBinQualitiesRefusesAPhred64File() async throws {
        let root = try TestTempDirectory.make(prefix: "legacy-phred64-bin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("illumina15.fastq")
        try Self.illumina15Records().write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("binned.fastq.gz")
        do {
            _ = try await FASTQIngestionPipeline().binQualities(of: input, into: output, scheme: .fiveStep, threads: 2)
            XCTFail("a Phred+64 file was binned as Phred+33")
        } catch is QualityEncoding.LegacyPhred64Refusal {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the refusal came before any output was written")
        }
    }

    /// 200 reads of 100 bases with quality bytes 66 (`B`, Q2) to 104 (`h`, Q40), as Illumina 1.5 wrote them.
    private static func illumina15Records() -> String {
        let bases = String(String(repeating: "ACGT", count: 26).prefix(100))
        var text = ""
        for read in 0..<200 {
            let quality = String(decoding: (0..<100).map { UInt8(66 + (read * 7 + $0 * 3) % 39) }, as: UTF8.self)
            text += "@r\(read)\n\(bases)\n+\n\(quality)\n"
        }
        return text
    }

    /// `file.gz` beside `file`, written by `/usr/bin/gzip`, which keeps the original.
    private static func gzipped(_ file: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -k wrote the test's gzip file")
        return file.appendingPathExtension("gz")
    }
}
