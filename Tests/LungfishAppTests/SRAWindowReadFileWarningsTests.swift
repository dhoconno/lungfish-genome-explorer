// SRAWindowReadFileWarningsTests.swift - The window's SRA download names what it leaves out, as fetch sra download does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

/// Review B of sub-phase 2.1, the window side.
/// - B-N2. The window imported a run's mates and deleted a third read file,
///   `<run>_3`, with the staging folder without a word. The row now logs the
///   warning `fetch sra download` prints, and the run carries it to the
///   bundle's provenance under `layoutWarning`.
/// - B-N3. A lone mate 1 of a run neither archive gives a layout for imports
///   as single reads with a warning, and a cancelled NCBI lookup cancels the
///   run and removes its folder.
/// ENA and NCBI are a scripted `SRAScriptedArchives` and the SRA Toolkit a
/// scripted runner, so no test reaches the network or spawns a tool.
final class SRAWindowReadFileWarningsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-warnings")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let thirdFileWarning = "SRR1_3.fastq.gz holds reads beyond mates 1 and 2 and is not imported with the run"

    // MARK: - B-N2

    func testAThirdReadFileFromENAIsLoggedAndCarriedToTheRunsRecord() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.runWithAThirdFile))
        let lines = SRAChecksLines()

        let staged = try await stage(archives: archives, lines: lines)
        defer { staged.removeFolder() }

        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["SRR1_1.fastq.gz", "SRR1_2.fastq.gz"])
        XCTAssertEqual(staged.layoutWarning, Self.thirdFileWarning)
        XCTAssertEqual(lines.values, [Self.thirdFileWarning], "the row logs the warning")
    }

    func testTheWindowAndFetchSRADownloadRecordTheSameWarning() async throws {
        let window = SRAScriptedArchives()
        let cli = SRAScriptedArchives()
        for archives in [window, cli] {
            archives.listOnENA("SRR1", .init(files: Self.runWithAThirdFile))
        }

        let staged = try await stage(archives: window)
        defer { staged.removeFolder() }
        let folder = root.appendingPathComponent("cli", isDirectory: true)
        let service = SRAService(ncbiService: NCBIService(httpClient: cli, environment: [:]), httpClient: cli)
        let command = try SRADownloadSubcommand.parse(["SRR1", "--output-dir", folder.path, "--quiet"])
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        let recorded = try XCTUnwrap(ProvenanceRecorder.load(from: folder))

        XCTAssertEqual(recorded.parameters["layoutWarning"], staged.layoutWarning.map(ParameterValue.string))
    }

    // MARK: - B-N3

    func testALoneMateOneOfARunNeitherArchiveListsImportsWithAWarning() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        archives.failOnNCBI(.down)
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)

        let staged = try await stage(
            archives: archives, toolkit: SRAWindowDownloadChecksTests.loneMateOne,
            lookUpNCBIRun: { await service.ncbiRunInfo(forRun: "SRR1") }
        )
        defer { staged.removeFolder() }

        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["SRR1_1.fastq"])
        XCTAssertEqual(
            staged.layoutWarning,
            "No layout of SRR1 came from ENA or NCBI and only SRR1_1.fastq arrived, so its reads import as single-end reads"
        )
    }

    func testACancelledNCBILookupCancelsTheRunAndRemovesItsFolder() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        archives.failOnNCBI(.cancelled)
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives)
        let batch = batch

        let run = Task {
            try await SRAWindowRunDownload.stage(
                accession: "SRR1",
                preference: .ena,
                lookUpNCBIRun: { await service.ncbiRunInfo(forRun: "SRR1") },
                in: batch,
                lookUpRoute: { try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: "SRR1") },
                mirrorFile: { url, _, _ in try await archives.mirrorFile(url) },
                toolkit: { _, folder in
                    try await SRAService(toolkitRunner: SRAWindowDownloadChecksTests.loneMateOne)
                        .downloadFASTQ(accession: "SRR1", outputDir: folder)
                }
            )
        }

        do {
            let staged = try await run.value
            staged.removeFolder()
            XCTFail("a cancelled NCBI lookup must cancel the run, not import \(staged.reads.files)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: batch.appendingPathComponent("SRR1").path),
            "the run's folder is removed"
        )
    }

    // MARK: - Helpers

    private var batch: URL { root.appendingPathComponent("batch", isDirectory: true) }

    /// Both mates of SRR1 and a third read file, as ENA lists a run whose
    /// spots hold three reads.
    static var runWithAThirdFile: [(name: String, data: Data)] {
        SRAWindowDownloadChecksTests.pair("SRR1") + [("SRR1_3.fastq.gz", Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
            0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        ]))]
    }

    /// Stages SRR1 under Prefer ENA as the window does, with ENA's lookup and
    /// mirror answered by `archives` and the toolkit given.
    private func stage(
        archives: SRAScriptedArchives,
        toolkit: SRAToolkitRunner = SRAWindowDownloadChecksTests.failingPrefetch,
        lookUpNCBIRun: (() async -> SRARunInfo?)? = nil,
        lines: SRAChecksLines = SRAChecksLines()
    ) async throws -> SRAWindowStagedRun {
        let service = SRAService(toolkitRunner: toolkit)
        return try await SRAWindowRunDownload.stage(
            accession: "SRR1",
            preference: .ena,
            lookUpNCBIRun: lookUpNCBIRun,
            in: batch,
            lookUpRoute: { try await ENAService(httpClient: archives).fastqDownloadRoute(forRun: "SRR1") },
            mirrorFile: { url, _, _ in try await archives.mirrorFile(url) },
            toolkit: { _, folder in try await service.downloadFASTQ(accession: "SRR1", outputDir: folder) },
            log: { lines.append($0) }
        )
    }
}
