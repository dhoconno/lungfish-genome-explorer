// SRAWindowDownloadSourceTests.swift - The window's "Download source" setting reaches every SRA download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Owner request of 2026-10-05: the SRA search window has an advanced
/// "Download source" setting, Prefer ENA (the default) or Prefer NCBI. It is
/// stored in UserDefaults, every download the window starts reads it, and the
/// run's provenance records it with the source that served the run. The
/// mirror is scripted and the toolkit writes recorded fasterq-dump output, so
/// no test reaches the network or spawns a tool.
final class SRAWindowDownloadSourceTests: XCTestCase {

    private static let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-download-source")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The setting

    @MainActor
    func testThePopupStoresTheChoiceWhereTheDownloadReadsIt() throws {
        let suite = "sra-window-download-source-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = SRADownloadSourcePicker.storage(in: defaults)
        XCTAssertEqual(storage.wrappedValue, .ena, "Prefer ENA is the default")
        storage.wrappedValue = .ncbi
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ncbi)
        XCTAssertEqual(SRADownloadSourcePicker.storage(in: defaults).wrappedValue, .ncbi, "the choice persists")
    }

    func testThePopupNamesItsChoicesAndTheTradeOff() {
        XCTAssertEqual(SRADownloadSourcePreference.allCases.map(\.menuTitle), ["Prefer ENA", "Prefer NCBI"])
        XCTAssertEqual(SRADownloadSourcePicker.title, "Download source")
        XCTAssertTrue(SRADownloadSourcePreference.tradeOff.contains("ENA serves ready FASTQ files"))
        XCTAssertTrue(SRADownloadSourcePreference.tradeOff.contains("faster when ENA is slow"))
    }

    // MARK: - The download

    func testPreferENAKeepsTheMirrorFirst() async throws {
        let toolkitCalls = Counter()
        let staged = try await stage(preference: .ena, mirror: .serves, toolkit: .recorded, toolkitCalls: toolkitCalls)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .ena)
        XCTAssertEqual(staged.download.preference, .ena)
        XCTAssertEqual(toolkitCalls.value, 0)
    }

    func testPreferNCBIFetchesWithTheToolkitAndNeverTouchesTheMirror() async throws {
        let toolkitCalls = Counter()
        let staged = try await stage(preference: .ncbi, mirror: .failsTest, toolkit: .recorded, toolkitCalls: toolkitCalls)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .sraToolkit)
        XCTAssertEqual(staged.download.preference, .ncbi)
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(Self.run)_1.fastq", "\(Self.run)_2.fastq", "\(Self.run).fastq"])
        XCTAssertEqual(toolkitCalls.value, 1)
    }

    func testPreferNCBIFallsBackToTheMirrorWhenTheToolkitFailsAndLogsWhy() async throws {
        let toolkitCalls = Counter()
        let lines = Lines()
        let staged = try await stage(
            preference: .ncbi, mirror: .serves, toolkit: .failsAfterWritingAMate, toolkitCalls: toolkitCalls, lines: lines
        )
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .enaAfterFailedToolkit)
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staged.folder.path).sorted(),
            ["\(Self.run)_1.fastq.gz", "\(Self.run)_2.fastq.gz"],
            "nothing the toolkit wrote is left beside ENA's files"
        )
        XCTAssertTrue(lines.values.contains { $0.contains("SRA Toolkit failed") && $0.contains("ENA") }, "\(lines.values)")
    }

    func testPreferNCBIFallsBackToTheMirrorWhenTheToolkitIsMissing() async throws {
        let staged = try await stage(preference: .ncbi, mirror: .serves, toolkit: .missing, toolkitCalls: Counter())
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .enaAfterMissingToolkit)
    }

    func testPreferNCBIFailsWithBothReasonsWhenTheMirrorFailsToo() async throws {
        do {
            let staged = try await stage(preference: .ncbi, mirror: .answersHTML, toolkit: .missing, toolkitCalls: Counter())
            staged.removeFolder()
            XCTFail("both sources failed, so the run must fail")
        } catch let error as SRAError {
            XCTAssertTrue(error.localizedDescription.contains("Toolkit"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch/\(Self.run)").path))
    }

    func testTheProvenanceRecordsThePreferenceAndTheSourceUsed() async throws {
        let staged = try await stage(preference: .ncbi, mirror: .serves, toolkit: .missing, toolkitCalls: Counter())
        defer { staged.removeFolder() }
        let bundle = root.appendingPathComponent("\(Self.run).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: fastq)
        let arguments = ["import", "fastq"] + staged.reads.files.map(\.path)

        try writeGUISRAFASTQImportProvenance(
            accession: Self.run,
            readRecord: nil,
            downloadSource: staged.download.source.rawValue,
            preferredSource: staged.download.preference,
            enaDownloadSteps: staged.download.enaSteps,
            toolkitDownloadTraces: [],
            cliArguments: arguments,
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: staged.reads.files,
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast"
        )

        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
        XCTAssertEqual(run.parameters["preferredSource"], .string("ncbi"))
        XCTAssertEqual(run.parameters["downloadSource"], .string("ENA (SRA Toolkit not installed)"))
        XCTAssertEqual(run.parameters["condaEnvironment"], .string("none"))
    }

    // MARK: - Helpers

    private enum Mirror {
        case serves
        case answersHTML
        case failsTest
    }

    private enum Toolkit {
        case recorded
        case missing
        case failsAfterWritingAMate
    }

    /// An empty gzip stream, which passes ENA's download check.
    private static let gzipStream = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    private func stage(
        preference: SRADownloadSourcePreference,
        mirror: Mirror,
        toolkit: Toolkit,
        toolkitCalls: Counter,
        lines: Lines = Lines()
    ) async throws -> SRAWindowStagedRun {
        let run = Self.run
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)"
        let size = Self.gzipStream.count
        let json = """
        {"run_accession": "\(run)", "library_layout": "PAIRED",
         "fastq_ftp": "\(folder)/\(run)_1.fastq.gz;\(folder)/\(run)_2.fastq.gz",
         "fastq_bytes": "\(size);\(size)"}
        """
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        let emptyHome = root.appendingPathComponent("home", isDirectory: true)
        let service: SRAService
        switch toolkit {
        case .recorded:
            service = SRAService(toolkitRunner: recorded.runner)
        case .missing:
            service = SRAService(homeDirectoryProvider: { emptyHome })
        case .failsAfterWritingAMate:
            let fasterq = URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
            service = SRAService(toolkitRunner: SRAToolkitRunner(
                prefetch: URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch"), fasterqDump: fasterq
            ) { executable, arguments in
                guard executable == fasterq, let index = arguments.firstIndex(of: "-O") else {
                    return SRAToolkitRunner.Result(exitCode: 0)
                }
                try Data("@\(run).1\nAC".utf8).write(
                    to: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("\(run)_1.fastq")
                )
                return SRAToolkitRunner.Result(exitCode: 3, stderr: "disk full")
            })
        }
        return try await SRAWindowRunDownload.stage(
            accession: run,
            route: .enaMirror(record),
            preference: preference,
            in: root.appendingPathComponent("batch", isDirectory: true),
            mirrorFile: { _, _, _ in
                switch mirror {
                case .serves: return Self.gzipStream
                case .answersHTML: return Data("<html>Index of</html>".utf8)
                case .failsTest:
                    XCTFail("Prefer NCBI with a working toolkit fetches nothing from ENA's mirror")
                    return Self.gzipStream
                }
            },
            toolkit: { _, folder in
                toolkitCalls.increment()
                return try await service.downloadFASTQ(accession: run, outputDir: folder)
            },
            log: { lines.append($0) }
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}
