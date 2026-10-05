// SRAWindowBatchStagingTests.swift - Each run of a window batch imports exactly its own reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// The window downloads a batch of SRA runs into one batch folder, and
/// `startENADownloadTask` stages each run with `SRAWindowRunDownload.stage`
/// and removes the run's folder after the import or on failure. A run whose
/// import failed must never hand its files to the next run, and a paired run
/// imports as a pair or not at all. The SRA Toolkit is a scripted runner
/// behind the real `SRAService.downloadFASTQ`, so no test spawns a tool or
/// reaches the network.
final class SRAWindowBatchStagingTests: XCTestCase {

    func testBatchImportsEachRunsOwnReadsBesideAnotherRunsFilesAndAStaleMate() async throws {
        let batchDir = try TestTempDirectory.make(prefix: "sra-window-batch")
        defer { TestTempDirectory.cleanup(batchDir) }
        // A run whose import failed left its pair, and a broken transfer left
        // one mate of a run that is single-end in this batch.
        let leftovers = ["SRR100_1.fastq", "SRR100_2.fastq", "SRR300_2.fastq.gz"]
        for name in leftovers {
            try Data("@\(name)\n".utf8).write(to: batchDir.appendingPathComponent(name))
        }
        let sra = SRAService(toolkitRunner: Self.toolkitRunner(reads: [
            "SRR200": ["SRR200_1.fastq", "SRR200_2.fastq"],
            "SRR300": ["SRR300.fastq"],
        ]))

        var imported: [String: [String]] = [:]
        for accession in ["SRR200", "SRR300"] {
            let staged = try await SRAWindowRunDownload.stage(
                accession: accession,
                route: .sraToolkit(enaRecord: nil, reason: "ENA returned HTTP 500 (server error) for \(accession)"),
                in: batchDir,
                mirrorFile: { url, _, _ in
                    XCTFail("the toolkit route fetched \(url.lastPathComponent) from ENA's mirror")
                    return Data()
                },
                toolkit: { _, folder in try await sra.downloadFASTQ(accession: accession, outputDir: folder) }
            )
            imported[accession] = try staged.reads.files.map { file in
                "\(file.lastPathComponent): \(try String(contentsOf: file, encoding: .utf8).prefix { $0 != "\n" })"
            }
            // The window's import of the first run fails, and its folder goes either way.
            staged.removeFolder()
        }

        XCTAssertEqual(imported["SRR200"], ["SRR200_1.fastq: @SRR200_1.fastq.1", "SRR200_2.fastq: @SRR200_2.fastq.1"])
        XCTAssertEqual(imported["SRR300"], ["SRR300.fastq: @SRR300.fastq.1"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: batchDir.path).sorted(),
            leftovers,
            "each run's folder is removed and nothing else is"
        )
    }

    func testFailedStagingRemovesTheRunsFolder() async throws {
        let batchDir = try TestTempDirectory.make(prefix: "sra-window-batch")
        defer { TestTempDirectory.cleanup(batchDir) }

        do {
            _ = try await SRAWindowRunDownload.stage(
                accession: "SRR200",
                route: .sraToolkit(enaRecord: nil, reason: "ENA has no record of SRR200"),
                in: batchDir,
                mirrorFile: { _, _, _ in Data() },
                toolkit: { _, folder in
                    // The toolkit wrote one mate and then failed.
                    try Data("@SRR200.1\n".utf8).write(to: folder.appendingPathComponent("SRR200_1.fastq"))
                    throw SRAError.conversionFailed("fasterq-dump stopped")
                }
            )
            XCTFail("a failed toolkit download must fail the run")
        } catch is SRAError {
            // Expected.
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: batchDir.path), [])
    }

    // MARK: - A paired run imports as a pair or not at all

    func testMatesImportAsAPairBesideTheUnpairedFile() throws {
        let reads = try SRAWindowRunReads(
            stagedFiles: Self.files(["SRR200.fastq.gz", "SRR200_2.fastq.gz", "SRR200_1.fastq.gz"]),
            accession: "SRR200",
            listedAsPaired: true
        )

        XCTAssertEqual(reads.files.map(\.lastPathComponent), ["SRR200_1.fastq.gz", "SRR200_2.fastq.gz"])
    }

    func testALoneSecondMateFails() {
        XCTAssertThrowsError(try SRAWindowRunReads(
            stagedFiles: Self.files(["SRR200_2.fastq"]),
            accession: "SRR200",
            listedAsPaired: false
        ))
    }

    func testALoneFirstMateOfARunListedAsPairedFails() {
        XCTAssertThrowsError(try SRAWindowRunReads(
            stagedFiles: Self.files(["SRR200_1.fastq"]),
            accession: "SRR200",
            listedAsPaired: true
        ))
    }

    func testAFirstMateBesideTheUnpairedFileWithoutTheSecondMateFails() {
        XCTAssertThrowsError(try SRAWindowRunReads(
            stagedFiles: Self.files(["SRR200_1.fastq", "SRR200.fastq"]),
            accession: "SRR200",
            listedAsPaired: false
        ))
    }

    func testAnotherRunsFilesNeverImport() {
        XCTAssertThrowsError(try SRAWindowRunReads(
            stagedFiles: Self.files(["SRR100_1.fastq", "SRR100_2.fastq"]),
            accession: "SRR200",
            listedAsPaired: false
        ))
    }

    func testOneFileImportsAsSingleReads() throws {
        for name in ["SRR300.fastq.gz", "SRR300_1.fastq"] {
            let reads = try SRAWindowRunReads(stagedFiles: Self.files([name]), accession: "SRR300", listedAsPaired: false)
            XCTAssertEqual(reads.files.map(\.lastPathComponent), [name])
            XCTAssertNil(reads.r2)
        }
    }

    // MARK: - Helpers

    private static func files(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/staging/run").appendingPathComponent($0) }
    }

    /// A toolkit whose `prefetch` writes the run's archive and whose
    /// `fasterq-dump` writes the reads `reads` lists for the run, each
    /// starting with a header naming its file.
    private static func toolkitRunner(reads: [String: [String]]) -> SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { executable, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "-O"))
            let outputDirectory = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                let archiveFolder = outputDirectory.appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: archiveFolder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            let accession = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
            for name in reads[accession] ?? [] {
                try Data("@\(name).1\nACGT\n+\nIIII\n".utf8).write(to: outputDirectory.appendingPathComponent(name))
            }
            return SRAToolkitRunner.Result(exitCode: 0)
        }
    }
}
