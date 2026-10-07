// SRADownloadChecksTests.swift - The checks every SRA download route shares, in LungfishCore
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// Lane L1 of sub-phase 2.1 closes the SRA download notes of the Phase 1.5
/// review (f5-f6-rereview.md). These tests pin the shared checks in
/// LungfishCore that the window and `lungfish-cli fetch sra download` both
/// run. They are the MD5 check (F5-N2), the run accession check (F5-N6), the
/// one-line failure reasons (F5-N3), the staging of ENA's files (F5-N1,
/// F5-N8) and the lone-mate rule with NCBI's LibraryLayout (F7-N1). ENA and NCBI are a
/// scripted `SRAScriptedArchives` and the SRA Toolkit a scripted runner, so
/// no test reaches the network or spawns a tool.
final class SRADownloadChecksTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-download-checks")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - MD5 (F5-N2)

    func testAFileWhoseMD5DiffersFromENAsListingFailsTheCheckWithOneLine() throws {
        let file = root.appendingPathComponent("SRR1_1.fastq.gz")
        try Self.mate1.write(to: file)
        var altered = Self.mate1
        altered[altered.count - 1] ^= 0xff
        let listed = SRAScriptedArchives.md5(altered)

        XCTAssertThrowsError(try ENAFASTQDownloadValidator.validate(
            fileURL: file, expectedBytes: Int64(Self.mate1.count), expectedMD5: listed
        )) { error in
            XCTAssertEqual(
                error as? ENAFASTQDownloadValidator.Failure,
                .md5Mismatch(filename: "SRR1_1.fastq.gz", expected: listed, actual: SRAScriptedArchives.md5(Self.mate1))
            )
            XCTAssertFalse(error.localizedDescription.contains("\n"))
        }
        XCTAssertNoThrow(try ENAFASTQDownloadValidator.validate(
            fileURL: file, expectedBytes: Int64(Self.mate1.count), expectedMD5: SRAScriptedArchives.md5(Self.mate1).uppercased()
        ))
        XCTAssertNoThrow(
            try ENAFASTQDownloadValidator.validate(fileURL: file, expectedBytes: nil, expectedMD5: "not-a-checksum"),
            "a value that is no MD5 is not compared"
        )
    }

    func testTheListedMD5sAlignWithENAsFiles() throws {
        let json = """
        {"run_accession": "SRR1", "fastq_ftp": "a/SRR1_1.fastq.gz;a/SRR1_2.fastq.gz",
         "fastq_md5": "0123456789ABCDEF0123456789abcdef;"}
        """
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        XCTAssertEqual(ENAFASTQDownloadValidator.expectedMD5s(for: record), ["0123456789abcdef0123456789abcdef", nil])
    }

    // MARK: - The run ENA answers with (F5-N6)

    func testARecordOfAnotherRunNeverServesTheRun() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRX100", .init(files: Self.pair("SRR999"), answeredAccession: "SRR999"))

        let route = try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: "SRX100")

        guard case .sraToolkit(let record, let reason) = route else {
            return XCTFail("ENA's record of SRR999 must not serve SRX100, got \(route)")
        }
        XCTAssertNil(record)
        XCTAssertEqual(reason, "ENA has no record of SRX100")
    }

    func testAListingOfOneMateOfAPairedRunTakesTheToolkitRoute() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(layout: "PAIRED", files: [("SRR1_1.fastq.gz", Self.mate1)]))
        archives.listOnENA("SRR2", .init(layout: "SINGLE", files: [("SRR2_2.fastq.gz", Self.mate2)]))

        let lone1 = try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: "SRR1")
        let lone2 = try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: "SRR2")

        XCTAssertEqual(lone1.toolkitReason, "ENA lists only mate 1 of the paired run SRR1")
        XCTAssertEqual(lone1.enaRecord?.runAccession, "SRR1", "ENA's record still gives the metadata")
        XCTAssertEqual(lone2.toolkitReason, "ENA lists only mate 2 of SRR2")
    }

    // MARK: - ENA's files on the CLI route (F5-N1, F5-N2, F5-N8)

    func testAMirrorFileThatFailsItsMD5StopsTheENADownloadAndNamesTheFile() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        var altered = Self.mate1
        altered[altered.count - 1] ^= 0xff
        archives.serveOnMirror("SRR1_1.fastq.gz", altered)
        let output = root.appendingPathComponent("out", isDirectory: true)

        do {
            _ = try await Self.service(archives).downloadFASTQFromENA(accession: "SRR1", outputDir: output)
            XCTFail("a file with another MD5 must fail the ENA download")
        } catch let failure as ENAFASTQDownloadFailure {
            XCTAssertEqual(failure.fallbackSource, .sraToolkitAfterIncompleteMirror)
            XCTAssertTrue(failure.message.contains("SRR1_1.fastq.gz has MD5"), failure.message)
            XCTAssertFalse(failure.message.contains("\n"))
        }
        XCTAssertEqual(archives.mirrorRequests, ["SRR1_1.fastq.gz"], "the first file that fails stops the download")
        XCTAssertEqual(try Self.entries(output), [], "nothing staged stays")
    }

    func testAFailedMateNeverReplacesAGoodCopyAlreadyInTheFolder() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        archives.failOnMirror("SRR1_2.fastq.gz", .status(503))
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let earlier = Data("an earlier good download".utf8)
        try earlier.write(to: output.appendingPathComponent("SRR1_1.fastq.gz"))

        do {
            _ = try await Self.service(archives).downloadFASTQFromENA(accession: "SRR1", outputDir: output)
            XCTFail("a mate the mirror refuses must fail the ENA download")
        } catch let failure as ENAFASTQDownloadFailure {
            XCTAssertEqual(failure.fallbackSource, .sraToolkitAfterFailedTransfer)
            XCTAssertEqual(failure.message, "ENA's mirror answered HTTP 503 for SRR1_2.fastq.gz")
        }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("SRR1_1.fastq.gz")), earlier)
        XCTAssertEqual(try Self.entries(output), ["SRR1_1.fastq.gz"])
    }

    func testACancelledTransferLeavesNoMateBehind() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        archives.failOnMirror("SRR1_2.fastq.gz", .cancelled)
        let output = root.appendingPathComponent("out", isDirectory: true)

        do {
            _ = try await Self.service(archives).downloadFASTQFromENA(accession: "SRR1", outputDir: output)
            XCTFail("a cancelled transfer must stop the download")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Self.entries(output), [], "no mate 1 and no hidden staging folder stays")
    }

    func testTheENADownloadPublishesTheWholeRunAndReportsENAsRecord() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        let output = root.appendingPathComponent("out", isDirectory: true)
        let records = SRACheckBox<[String]>([])

        let files = try await Self.service(archives).downloadFASTQFromENA(
            accession: "SRR1", outputDir: output,
            onRecord: { record in
                records.mutate { list in
                    let tag = list.isEmpty ? "first" : "again"
                    list.append("\(tag) \(record.runAccession)")
                }
            }
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["SRR1_1.fastq.gz", "SRR1_2.fastq.gz"])
        XCTAssertEqual(try Self.entries(output), ["SRR1_1.fastq.gz", "SRR1_2.fastq.gz"])
        XCTAssertEqual(try Data(contentsOf: files[1]), Self.mate2)
        XCTAssertEqual(records.value, ["first SRR1"], "ENA's record is reported once")
    }

    func testAnMD5FailureSendsTheRunToTheToolkitWithTheSharedLine() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let recorded = SRAToolkitRecordedRunner(testFile: #filePath)
        let archives = SRAScriptedArchives()
        archives.listOnENA(run, .init(files: Self.pair(run), listedMD5s: [String(repeating: "0", count: 32), SRAScriptedArchives.md5(Self.mate2)]))
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: recorded.runner)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let lines = SRACheckBox<[String]>([])
        let sources = SRACheckBox<[SRAFASTQDownloadSource]>([])

        let files = try await service.downloadFASTQWithFallback(
            accession: run, outputDir: output,
            onFallback: { line in lines.mutate { $0.append(line) } },
            onSource: { source in sources.mutate { $0.append(source) } }
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        XCTAssertEqual(sources.value, [.sraToolkitAfterIncompleteMirror])
        let line = try XCTUnwrap(lines.value.first)
        XCTAssertTrue(line.hasPrefix("ENA could not serve \(run), so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead."), line)
        XCTAssertTrue(line.contains("\(run)_1.fastq.gz has MD5"), line)
    }

    // MARK: - One-line failures (F5-N3)

    func testAFailedPrefetchFailsWithOneLineNamingTheToolAndItsErrorLine() async throws {
        let service = SRAService(toolkitRunner: Self.failingToolkit(prefetchExit: 3))

        do {
            _ = try await service.downloadFASTQ(accession: "SRR1", outputDir: root)
            XCTFail("a failed prefetch must fail the download")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Download failed: prefetch exited with status 3. prefetch.3.4.1 err: name not found while resolving query within virtual file system module - failed to resolve accession 'SRR1' - no data ( 404 )"
            )
        }
    }

    func testAFailedFasterqDumpFailsWithOneLineAndRemovesThePartialMate() async throws {
        let service = SRAService(toolkitRunner: Self.failingToolkit(fasterqExit: 3, partialMate: "SRR1_1.fastq"))

        do {
            _ = try await service.downloadFASTQ(accession: "SRR1", outputDir: root)
            XCTFail("a failed fasterq-dump must fail the download")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("\n"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("fasterq-dump exited with status 3"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SRR1_1.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("SRR1/SRR1.sra").path), "the archive stays")
    }

    func testACancelledFasterqDumpRemovesThePartialMate() async throws {
        let service = SRAService(toolkitRunner: Self.failingToolkit(fasterqCancels: true, partialMate: "SRR1_1.fastq"))

        do {
            _ = try await service.downloadFASTQ(accession: "SRR1", outputDir: root)
            XCTFail("a cancelled fasterq-dump must stop the download")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SRR1_1.fastq").path))
    }

    func testWhenBothArchivesFailTheErrorIsOneLineWithEachReasonOnce() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: archives, environment: [:]),
            httpClient: archives,
            toolkitRunner: Self.failingToolkit(prefetchExit: 3)
        )

        for preference in SRADownloadSourcePreference.allCases {
            do {
                _ = try await service.downloadFASTQ(accession: "SRR1", outputDir: root, preferring: preference)
                XCTFail("both archives failed")
            } catch {
                let message = error.localizedDescription
                XCTAssertFalse(message.contains("\n"), message)
                XCTAssertEqual(message.components(separatedBy: "Download failed:").count, 2, "said once: \(message)")
                XCTAssertTrue(message.contains("ENA: ENA returned HTTP 500 (server error) for SRR1"), message)
                XCTAssertTrue(message.contains("Toolkit: prefetch exited with status 3."), message)
            }
        }
    }

    // MARK: - The lone-mate rule reads NCBI's layout too (F7-N1)

    func testALoneMateOneOfARunNCBIListsAsPairedIsRefused() async throws {
        let asked = SRACheckBox(0)
        do {
            _ = try await SRARunReads.sorting(
                Self.files(["SRR1_1.fastq"]), accession: "SRR1", enaLayout: nil,
                ncbiLayout: { asked.mutate { $0 += 1 }; return "PAIRED" }
            )
            XCTFail("a lone mate 1 of a run NCBI lists as paired must be refused")
        } catch let failure as SRARunReads.Failure {
            XCTAssertEqual(failure.kind, .onlyMate1(listedBy: "NCBI"))
            XCTAssertEqual(failure.message, "Only mate 1 of SRR1 arrived and NCBI lists the run as paired")
        }
        XCTAssertEqual(asked.value, 1)
    }

    func testENAsLayoutDecidesWithoutAskingNCBI() async throws {
        let asked = SRACheckBox(0)
        let single = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq"]), accession: "SRR1", enaLayout: "SINGLE",
            ncbiLayout: { asked.mutate { $0 += 1 }; return "PAIRED" }
        )
        let pair = try await SRARunReads.sorting(
            Self.files(["SRR1_1.fastq", "SRR1_2.fastq"]), accession: "SRR1", enaLayout: nil,
            ncbiLayout: { asked.mutate { $0 += 1 }; return "PAIRED" }
        )

        XCTAssertNil(single.reads.r2)
        XCTAssertNil(single.layoutWarning)
        XCTAssertNotNil(pair.reads.r2)
        XCTAssertNil(pair.layoutWarning)
        XCTAssertEqual(asked.value, 0, "NCBI is asked only when ENA gives no layout and no mate 2 arrived")
    }

    func testOneFileOfARunListedAsPairedImportsAsSingleReadsWithAWarning() async throws {
        let byNCBI = try await SRARunReads.sorting(
            Self.files(["SRR1.fastq"]), accession: "SRR1", enaLayout: nil, ncbiLayout: { "PAIRED" }
        )
        let byENA = try await SRARunReads.sorting(
            Self.files(["SRR1.fastq.gz"]), accession: "SRR1", enaLayout: "PAIRED", ncbiLayout: { nil }
        )

        XCTAssertEqual(byNCBI.reads.files.map(\.lastPathComponent), ["SRR1.fastq"])
        XCTAssertEqual(byNCBI.layoutWarning, "NCBI lists SRR1 as paired but only one read file arrived; imported as single-end reads")
        XCTAssertEqual(byENA.layoutWarning, "ENA lists SRR1 as paired but only one read file arrived; imported as single-end reads")
    }

    func testNCBIsRunInfoIsLookedUpForOneRun() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnNCBI("SRR1", layout: "PAIRED")
        let service = Self.service(archives)

        let found = await service.ncbiRunInfo(forRun: "SRR1")
        let missing = await service.ncbiRunInfo(forRun: "SRR2")

        XCTAssertEqual(found?.libraryLayout, "PAIRED")
        XCTAssertNil(missing)
        XCTAssertEqual(archives.ncbiRequests, ["ncbi SRR1", "ncbi SRR2"])
    }

    func testOnlyAnAccessionThatNamesOneFolderNamesOne() {
        for name in ["", ".", "..", "a/b", "/", "SRR1\u{0}"] {
            XCTAssertFalse(SRAAccessionParser.namesOneFolder(name), name)
        }
        XCTAssertTrue(SRAAccessionParser.namesOneFolder("SRR1"))
    }

    // MARK: - Helpers

    /// Gzip members whose bytes differ, so each mate has its own MD5.
    static let mate1 = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ])
    static let mate2 = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ])

    static func pair(_ run: String) -> [(name: String, data: Data)] {
        [("\(run)_1.fastq.gz", mate1), ("\(run)_2.fastq.gz", mate2)]
    }

    private static func service(_ archives: SRAScriptedArchives) -> SRAService {
        SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)
    }

    private static func files(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/staging/run").appendingPathComponent($0) }
    }

    private static func entries(_ folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// sra-tools' standard error for a run NCBI cannot resolve, several lines
    /// long, as prefetch 3.4.1 writes it.
    static let prefetchStandardError = """
    2026-10-06T12:00:00 prefetch.3.4.1 err: name not found while resolving query within virtual file system module - failed to resolve accession 'SRR1' - no data ( 404 )

    2026-10-06T12:00:00 prefetch.3.4.1: 1) failed to download 'SRR1': cannot resolve accession
    """

    /// A toolkit whose `prefetch` writes the archive or fails with
    /// `prefetchExit`, and whose `fasterq-dump` writes `partialMate` and then
    /// fails with `fasterqExit` or is cancelled.
    static func failingToolkit(
        prefetchExit: Int32 = 0,
        fasterqExit: Int32 = 0,
        fasterqCancels: Bool = false,
        partialMate: String? = nil
    ) -> SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { executable, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "-O"))
            let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                guard prefetchExit == 0 else {
                    return SRAToolkitRunner.Result(exitCode: prefetchExit, stderr: prefetchStandardError)
                }
                let folder = output.appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: folder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            if let partialMate {
                try Data("@r1\nAC".utf8).write(to: output.appendingPathComponent(partialMate))
            }
            if fasterqCancels {
                throw CancellationError()
            }
            return SRAToolkitRunner.Result(
                exitCode: fasterqExit,
                stderr: "2026-10-06T12:00:01 fasterq-dump.3.4.1 err: storage exhausted while writing file within file system module\nfasterq-dump quit with error code 3"
            )
        }
    }
}

/// A value several closures add to, guarded by a lock.
private final class SRACheckBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
