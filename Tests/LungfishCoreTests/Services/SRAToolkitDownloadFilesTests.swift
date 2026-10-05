// SRAToolkitDownloadFilesTests.swift - An SRA Toolkit download keeps only the files of the run it fetched
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// `SRAService.downloadFASTQ` runs `prefetch` and `fasterq-dump` into a folder
/// that can already hold other runs' files and older files of the same run.
/// The window's batch and `lungfish-cli fetch sra download` both take the
/// files it returns as the run's reads, so it returns only the reads of this
/// run that the download wrote. Once `fasterq-dump` succeeds it removes the
/// archive `prefetch` added, and it never removes a file that was there
/// before. The toolkit is a scripted runner, so no test spawns a tool or
/// reaches the network.
final class SRAToolkitDownloadFilesTests: XCTestCase {

    func testDownloadReturnsOnlyThisRunsReadsBesideAnotherRunsFilesAndAStaleMate() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        // Another run's pair, left by a failed import, and a mate of this run
        // from an earlier ENA download.
        let leftovers = ["SRR100_1.fastq", "SRR100_2.fastq", "SRR200_2.fastq.gz"]
        for name in leftovers {
            try Data("@\(name)\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let traces = TraceRecorder()
        let service = SRAService(toolkitRunner: Self.runner(writes: ["SRR200_1.fastq", "SRR200_2.fastq"]))

        let files = try await service.downloadFASTQ(
            accession: "SRR200",
            outputDir: folder,
            trace: { traces.record($0) }
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR200_1.fastq", "SRR200_2.fastq"])
        XCTAssertEqual(
            traces.steps.first { $0.toolName == "fasterq-dump" }?.outputs.map(\.lastPathComponent),
            ["SRR200_1.fastq", "SRR200_2.fastq"],
            "the fasterq-dump step records only this run's reads"
        )
        for name in leftovers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
        }
    }

    func testDownloadReturnsASingleEndRunsOneFile() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        try Data("@SRR100.1\n".utf8).write(to: folder.appendingPathComponent("SRR100.fastq"))
        let service = SRAService(toolkitRunner: Self.runner(writes: ["SRR300.fastq"]))

        let files = try await service.downloadFASTQ(accession: "SRR300", outputDir: folder)

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR300.fastq"])
    }

    func testDownloadFailsWhenFasterqDumpWritesNoReadOfThisRun() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        // Only older files of this run are there, so nothing was downloaded.
        for name in ["SRR200_1.fastq.gz", "SRR200_2.fastq.gz"] {
            try Data("@\(name)\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let service = SRAService(toolkitRunner: Self.runner(writes: []))

        do {
            let files = try await service.downloadFASTQ(accession: "SRR200", outputDir: folder)
            XCTFail("an older copy must not stand in for a download, got \(files.map(\.lastPathComponent))")
        } catch let error as SRAError {
            guard case .conversionFailed = error else {
                return XCTFail("expected a conversion failure, got \(error)")
            }
        }
    }

    func testDownloadRemovesTheArchivePrefetchAddedOnceFasterqDumpSucceeds() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        let service = SRAService(toolkitRunner: Self.runner(writes: ["SRR200_1.fastq", "SRR200_2.fastq"]))

        _ = try await service.downloadFASTQ(accession: "SRR200", outputDir: folder)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("SRR200").path),
            "the prefetch folder the download created is removed"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["SRR200_1.fastq", "SRR200_2.fastq"]
        )
    }

    func testDownloadKeepsAnArchiveTheFolderAlreadyHeld() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        let archiveFolder = folder.appendingPathComponent("SRR200", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: archiveFolder.appendingPathComponent("SRR200.sra"))
        // prefetch finds the archive and adds only its cache file.
        let service = SRAService(toolkitRunner: Self.runner(
            writes: ["SRR200_1.fastq", "SRR200_2.fastq"],
            prefetchWrites: ["SRR200.sra.vdbcache"]
        ))

        _ = try await service.downloadFASTQ(accession: "SRR200", outputDir: folder)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archiveFolder.path), ["SRR200.sra"])
    }

    func testDownloadKeepsTheArchiveWhenFasterqDumpFails() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-toolkit-files")
        defer { TestTempDirectory.cleanup(folder) }
        let service = SRAService(toolkitRunner: Self.runner(writes: [], fasterqExitCode: 3))

        do {
            _ = try await service.downloadFASTQ(accession: "SRR200", outputDir: folder)
            XCTFail("a failed fasterq-dump must fail the download")
        } catch let error as SRAError {
            guard case .conversionFailed = error else {
                return XCTFail("expected a conversion failure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SRR200/SRR200.sra").path))
    }

    // MARK: - Helpers

    /// A toolkit whose `prefetch` writes `prefetchWrites` under
    /// `<output>/<accession>/` and whose `fasterq-dump` writes `writes` into
    /// the output folder, as the real tools do.
    private static func runner(
        writes reads: [String],
        prefetchWrites: [String] = ["SRR200.sra"],
        fasterqExitCode: Int32 = 0
    ) -> SRAToolkitRunner {
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
                for name in prefetchWrites {
                    try Data("archive".utf8).write(to: archiveFolder.appendingPathComponent(name))
                }
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            guard fasterqExitCode == 0 else {
                return SRAToolkitRunner.Result(exitCode: fasterqExitCode, stderr: "fasterq-dump failed")
            }
            for name in reads {
                try Data("@\(name).1\nACGT\n+\nIIII\n".utf8).write(to: outputDirectory.appendingPathComponent(name))
            }
            return SRAToolkitRunner.Result(exitCode: 0)
        }
    }
}

private final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SRAService.FASTQDownloadStepTrace] = []

    var steps: [SRAService.FASTQDownloadStepTrace] { lock.withLock { recorded } }

    func record(_ step: SRAService.FASTQDownloadStepTrace) {
        lock.withLock { recorded.append(step) }
    }
}
