// SRAWindowDownloadChecksTests.swift - The window's SRA download runs the checks fetch sra download runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Lane L1 of sub-phase 2.1 checks five things in the window's SRA download.
/// - a file from ENA's mirror whose MD5 differs from ENA's listing takes the
///   SRA Toolkit route, and the failed attempt stays recorded (F5-N2, F5-N8),
/// - a run neither archive serves fails with one line (F5-N3),
/// - an accession that cannot name one folder removes nothing (F7-N3),
/// - NCBI's run info covers a run the last search did not (MSA session
///   follow-up) and its LibraryLayout refuses a lone mate (F7-N1),
/// - the provenance records the sra-tools version and no ENA file for a run
///   the toolkit fetched (F5-N8).
/// ENA and NCBI are a scripted `SRAScriptedArchives` and the SRA Toolkit the
/// recorded fasterq-dump output, so no test reaches the network or spawns a
/// tool.
final class SRAWindowDownloadChecksTests: XCTestCase {

    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-checks")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAMirrorFileWhoseMD5DiffersFallsBackToTheToolkitAndKeepsTheFailedAttempt() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let archives = SRAScriptedArchives()
        archives.listOnENA(run, .init(
            files: Self.pair(run),
            listedMD5s: [SRAScriptedArchives.md5(Self.mate1), String(repeating: "0", count: 32)]
        ))
        let lines = SRAChecksLines()

        let staged = try await stage(run, archives: archives, lines: lines)
        defer { staged.removeFolder() }

        XCTAssertEqual(staged.download.source, .sraToolkitAfterIncompleteMirror)
        let line = try XCTUnwrap(staged.download.fallbackMessage)
        XCTAssertTrue(line.hasPrefix("ENA could not serve \(run), so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead."), line)
        XCTAssertTrue(line.contains("\(run)_2.fastq.gz has MD5"), line)
        XCTAssertEqual(lines.values, [line], "the row logs the line fetch sra download prints")
        XCTAssertEqual(staged.download.enaSteps.map(\.toolName), ["https-download"], "mate 1 arrived before mate 2 failed")
        XCTAssertEqual(staged.download.enaSteps.first?.resolvedOptions?["attempt"], .string("failed"))
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        let left = try FileManager.default.contentsOfDirectory(atPath: staged.folder.path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".gz") }, "no file of ENA's attempt stays beside the toolkit's: \(left)")
    }

    func testWhenENAAndTheToolkitBothFailTheRunFailsWithOneLine() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()

        do {
            _ = try await stage("SRR1", archives: archives, toolkit: Self.failingPrefetch)
            XCTFail("both archives failed")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Download failed: ENA: ENA returned HTTP 500 (server error) for SRR1; Toolkit: prefetch exited with status 3. prefetch.3.4.1 err: name not found"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("SRR1").path))
    }

    func testAnAccessionThatCannotNameOneFolderFailsBeforeAnythingIsRemoved() async throws {
        // The batch sits two folders down, so even a wrong removal stays
        // inside this test's own folder.
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let batchDir = outer.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        let keepOuter = outer.appendingPathComponent("keep.txt")
        let keepBatch = batchDir.appendingPathComponent("SRR9_1.fastq")
        try Data("keep".utf8).write(to: keepOuter)
        try Data("keep".utf8).write(to: keepBatch)

        for accession in ["..", ".", "", "SRR1/..", "a/b"] {
            do {
                _ = try await SRAWindowRunDownload.stage(
                    accession: accession,
                    route: .sraToolkit(enaRecord: nil, reason: "ENA has no record of \(accession)"),
                    in: batchDir,
                    mirrorFile: { _, _, _ in Data() },
                    toolkit: { _, _ in [] }
                )
                XCTFail("\(accession) must not name a staging folder")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("cannot name a staging folder"), "\(accession): \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepOuter.path), "\(accession) removed the batch's parent folder")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepBatch.path), "\(accession) removed the batch folder")
        }
    }

    func testNCBIsRunInfoCoversARunTheSearchDidNot() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        archives.listOnNCBI(run, layout: "PAIRED")
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)
        let lookups = SRAChecksLines()

        let staged = try await stage(run, archives: archives, lookUpNCBIRun: {
            lookups.append("lookup")
            return await service.ncbiRunInfo(forRun: run)
        })
        defer { staged.removeFolder() }

        XCTAssertNil(staged.download.enaRecord)
        XCTAssertEqual(staged.ncbiRun?.libraryLayout, "PAIRED", "NCBI's record reaches the bundle's metadata")
        XCTAssertEqual(lookups.values, ["lookup"], "NCBI is asked once")

        let fromSearch = try JSONDecoder().decode(SRARunInfo.self, from: Data("""
        {"accession": "\(run)", "platform": "ILLUMINA", "libraryLayout": "PAIRED"}
        """.utf8))
        let searched = try await stage(run, archives: archives, ncbiRun: fromSearch, lookUpNCBIRun: {
            lookups.append("lookup")
            return nil
        })
        defer { searched.removeFolder() }
        XCTAssertEqual(lookups.values, ["lookup"], "a run the search covered asks NCBI nothing")
    }

    func testALoneMateOneOfARunNCBIListsAsPairedFails() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        archives.listOnNCBI("SRR1", layout: "PAIRED")
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)

        do {
            _ = try await stage("SRR1", archives: archives, toolkit: Self.loneMateOne, lookUpNCBIRun: {
                await service.ncbiRunInfo(forRun: "SRR1")
            })
            XCTFail("a lone mate 1 of a run NCBI lists as paired must fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Only mate 1 of SRR1 arrived and NCBI lists the run as paired, so it was not imported"
            )
        }
    }

    func testTheProvenanceRecordsTheSRAToolsVersionAndNoENAFileForAToolkitRun() throws {
        let version = try XCTUnwrap(ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version)
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data("""
        {"run_accession": "SRR1", "library_layout": "PAIRED", "fastq_ftp": "ftp.sra.ebi.ac.uk/a/SRR1_1.fastq.gz;ftp.sra.ebi.ac.uk/a/SRR1_2.fastq.gz"}
        """.utf8))
        let prefetch = SRAService.FASTQDownloadStepTrace(
            toolName: "prefetch", toolVersion: "sra-tools", command: ["prefetch", "SRR1"], inputs: ["SRR1"], outputs: [],
            exitCode: 0, wallTime: 1, stderr: "", startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 1)
        )

        let toolkitRun = try recordProvenance(source: .sraToolkitAfterIncompleteMirror, record: record, traces: [prefetch])
        let enaRun = try recordProvenance(source: .ena, record: record, traces: [])

        XCTAssertEqual(toolkitRun.steps.first?.toolVersion, "sra-tools \(version)", "as fetch sra download records it")
        XCTAssertEqual(toolkitRun.parameters["enaFastqURLs"], .array([]), "the reads came from none of ENA's files")
        XCTAssertEqual(enaRun.parameters["enaFastqURLs"], .array(record.fastqHTTPURLs.map { .string($0.absoluteString) }))
    }

    // MARK: - Helpers

    private var batch: URL { root.appendingPathComponent("batch", isDirectory: true) }

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

    /// Stages `run` under Prefer ENA as the window does, with ENA's lookup
    /// and mirror answered by `archives` and the toolkit given, by default
    /// the recorded fasterq-dump output.
    private func stage(
        _ run: String,
        archives: SRAScriptedArchives,
        toolkit: SRAToolkitRunner? = nil,
        ncbiRun: SRARunInfo? = nil,
        lookUpNCBIRun: (() async -> SRARunInfo?)? = nil,
        lines: SRAChecksLines = SRAChecksLines()
    ) async throws -> SRAWindowStagedRun {
        let service = SRAService(toolkitRunner: toolkit ?? recorded.runner)
        return try await SRAWindowRunDownload.stage(
            accession: run,
            preference: .ena,
            ncbiRun: ncbiRun,
            lookUpNCBIRun: lookUpNCBIRun,
            in: batch,
            lookUpRoute: { try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: run) },
            mirrorFile: { url, _, _ in try await archives.mirrorFile(url) },
            toolkit: { status, folder in
                lines.append(status.line)
                return try await service.downloadFASTQ(accession: run, outputDir: folder)
            }
        )
    }

    private func recordProvenance(
        source: SRAFASTQDownloadSource,
        record: ENAReadRecord,
        traces: [SRAService.FASTQDownloadStepTrace]
    ) throws -> WorkflowRun {
        let bundle = root.appendingPathComponent("SRR1-\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        try writeGUISRAFASTQImportProvenance(
            accession: "SRR1",
            readRecord: record,
            downloadSource: source.rawValue,
            enaDownloadSteps: [],
            toolkitDownloadTraces: traces,
            cliArguments: ["import", "fastq"],
            cliStartedAt: Date(timeIntervalSince1970: 2),
            cliCompletedAt: Date(timeIntervalSince1970: 3),
            stagedFASTQFiles: [],
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )
        return try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
    }

    /// A toolkit whose prefetch fails with several lines of standard error.
    static let failingPrefetch = SRAToolkitRunner(
        prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"),
        fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
    ) { _, _ in
        SRAToolkitRunner.Result(
            exitCode: 3,
            stderr: "2026-10-06T12:00:00 prefetch.3.4.1 err: name not found\n\n2026-10-06T12:00:00 prefetch.3.4.1: 1) failed to download"
        )
    }

    /// A toolkit whose fasterq-dump writes only mate 1 of the run.
    static let loneMateOne = SRAToolkitRunner(
        prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"),
        fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
    ) { executable, arguments in
        guard executable.lastPathComponent == "fasterq-dump", let index = arguments.firstIndex(of: "-O") else {
            return SRAToolkitRunner.Result(exitCode: 0)
        }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try Data("@r1\nAC\n+\nII\n".utf8).write(to: output.appendingPathComponent("SRR1_1.fastq"))
        return SRAToolkitRunner.Result(exitCode: 0)
    }
}

/// Lines logged by closures, guarded by a lock.
final class SRAChecksLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}
