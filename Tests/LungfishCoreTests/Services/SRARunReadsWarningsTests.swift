// SRARunReadsWarningsTests.swift - The lone-mate rule names the read files it leaves out and a layout nobody lists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// Review B of sub-phase 2.1 found two silent cases in `SRARunReads.sorting`,
/// the rule the window's SRA download and `lungfish-cli fetch sra download`
/// both sort a run's files with.
/// - B-N2. A third read file, `<run>_3` (or a later one), that ENA lists or
///   the SRA Toolkit writes was left out of the run's reads without a word.
/// - B-N3. With no layout from either archive, a lone mate 1 was taken as
///   single reads without a word, and a cancelled NCBI lookup counted as no
///   layout, so a cancelled download went on.
/// The rule's warning now names both cases, in one line, and a cancelled
/// lookup stops the sort. The SRA Toolkit is a scripted runner, so no test
/// reaches the network or spawns a tool.
final class SRARunReadsWarningsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-run-reads-warnings")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - B-N2, read files beyond mates 1 and 2

    func testAThirdReadFileIsLeftOutAndNamedInTheWarning() async throws {
        let sorted = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq.gz", "SRR1_2.fastq.gz", "SRR1_3.fastq.gz"]),
            accession: "SRR1", enaLayout: "PAIRED", ncbiLayout: { nil }
        )

        XCTAssertEqual(sorted.reads.files.map(\.lastPathComponent), ["SRR1_1.fastq.gz", "SRR1_2.fastq.gz"])
        XCTAssertEqual(sorted.layoutWarning, "SRR1_3.fastq.gz holds reads beyond mates 1 and 2 and is not imported with the run")
    }

    func testEveryLaterReadFileIsNamedInOneLine() async throws {
        let sorted = try await SRARunReads.sorting(
            Self.files(["SRR1_4.fastq", "SRR1_1.fastq", "SRR1_3.fastq", "SRR1_2.fastq", "SRR1.fastq"]),
            accession: "SRR1", enaLayout: nil, ncbiLayout: { nil }
        )

        XCTAssertEqual(sorted.reads.files.map(\.lastPathComponent), ["SRR1_1.fastq", "SRR1_2.fastq", "SRR1.fastq"])
        XCTAssertEqual(
            sorted.layoutWarning,
            "SRR1_3.fastq and SRR1_4.fastq hold reads beyond mates 1 and 2 and are not imported with the run"
        )
    }

    func testALayoutWarningAndALaterReadFileMakeOneLine() async throws {
        let sorted = try await SRARunReads.sorting(
            Self.files(["SRR1.fastq", "SRR1_3.fastq"]),
            accession: "SRR1", enaLayout: nil, ncbiLayout: { "PAIRED" }
        )

        XCTAssertEqual(
            sorted.layoutWarning,
            "NCBI lists SRR1 as paired but only one read file arrived; imported as single-end reads. "
                + "SRR1_3.fastq holds reads beyond mates 1 and 2 and is not imported with the run"
        )
    }

    func testFilesOfAnotherRunOrNoReadNumberAreNeverNamed() async throws {
        let sorted = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq", "SRR1_2.fastq", "SRR10_3.fastq", "SRR1_3.txt", "SRR1_x.fastq"]),
            accession: "SRR1", enaLayout: nil, ncbiLayout: { nil }
        )

        XCTAssertNil(sorted.layoutWarning)
    }

    func testTheToolkitReturnsTheLaterReadFilesItWrote() async throws {
        let folder = root.appendingPathComponent("toolkit", isDirectory: true)
        let service = SRAService(toolkitRunner: Self.toolkit(writes: ["SRR1_1.fastq", "SRR1_2.fastq", "SRR1_3.fastq"]))

        let files = try await service.downloadFASTQ(accession: "SRR1", outputDir: folder)

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR1_1.fastq", "SRR1_2.fastq", "SRR1_3.fastq"])
    }

    func testTheToolkitNeverReturnsALaterReadFileThatWasThereBefore() async throws {
        let folder = root.appendingPathComponent("toolkit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = folder.appendingPathComponent("SRR1_3.fastq")
        try Data("@earlier\nAC\n+\nII\n".utf8).write(to: earlier)
        let service = SRAService(toolkitRunner: Self.toolkit(writes: ["SRR1_1.fastq", "SRR1_2.fastq"]))

        let files = try await service.downloadFASTQ(accession: "SRR1", outputDir: folder)

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR1_1.fastq", "SRR1_2.fastq"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.path), "a file that was there before is never removed")
    }

    func testAFailedFasterqDumpRemovesTheLaterReadFileItWrote() async throws {
        let folder = root.appendingPathComponent("toolkit", isDirectory: true)
        let service = SRAService(toolkitRunner: Self.toolkit(writes: ["SRR1_1.fastq", "SRR1_3.fastq"], fasterqExit: 3))

        do {
            _ = try await service.downloadFASTQ(accession: "SRR1", outputDir: folder)
            XCTFail("a failed fasterq-dump must fail the download")
        } catch {}

        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix("SRR1_") }, "no partial read file stays: \(left)")
    }

    // MARK: - B-N3, a lone mate 1 with no layout, and a cancelled lookup

    func testALoneMateOneWithNoLayoutFromEitherArchiveWarns() async throws {
        let sorted = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq.gz"]), accession: "SRR1", enaLayout: nil, ncbiLayout: { nil }
        )

        XCTAssertEqual(sorted.reads.files.map(\.lastPathComponent), ["SRR1_1.fastq.gz"])
        XCTAssertEqual(
            sorted.layoutWarning,
            "No layout of SRR1 came from ENA or NCBI and only SRR1_1.fastq.gz arrived, so its reads import as single-end reads"
        )
    }

    func testAListedSingleLayoutOrAFileWithoutAMateNumberDoesNotWarn() async throws {
        let listed = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq"]), accession: "SRR1", enaLayout: nil, ncbiLayout: { "SINGLE" }
        )
        let unsuffixed = try await SRARunReads.sorting(
            Self.files(["SRR1.fastq"]), accession: "SRR1", enaLayout: nil, ncbiLayout: { nil }
        )

        XCTAssertNil(listed.layoutWarning)
        XCTAssertNil(unsuffixed.layoutWarning)
    }

    func testACancelledNCBILookupStopsTheSort() async throws {
        let sort = Task {
            try await SRARunReads.sorting(
                Self.files(["SRR1_1.fastq"]), accession: "SRR1", enaLayout: nil,
                ncbiLayout: {
                    // NCBI's lookup answers nil when its task is cancelled.
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                }
            )
        }

        do {
            let sorted = try await sort.value
            XCTFail("a cancelled lookup must stop the sort, not take \(sorted.reads.files) as single reads")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testNCBIsRunInfoIsNilInAnOutage() async throws {
        let archives = SRAScriptedArchives()
        archives.failOnNCBI(.down)
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)

        let info = await service.ncbiRunInfo(forRun: "SRR1")

        XCTAssertNil(info)
        XCTAssertEqual(archives.ncbiRequests, ["ncbi SRR1"])
    }

    // MARK: - Helpers

    private static func files(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/staging/run").appendingPathComponent($0) }
    }

    /// A toolkit whose `prefetch` writes the run's archive and whose
    /// `fasterq-dump` writes `names` and exits with `fasterqExit`.
    static func toolkit(writes names: [String], fasterqExit: Int32 = 0) -> SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { executable, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "-O"))
            let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                let folder = output.appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: folder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            for name in names {
                try Data("@\(name)\nACGT\n+\nIIII\n".utf8).write(to: output.appendingPathComponent(name))
            }
            return SRAToolkitRunner.Result(
                exitCode: fasterqExit,
                stderr: fasterqExit == 0 ? "" : "fasterq-dump.3.4.1 err: disk full"
            )
        }
    }
}
