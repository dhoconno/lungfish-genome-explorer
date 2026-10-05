// SRADownloadPreferSourceTests.swift - fetch sra download --prefer-source picks the archive tried first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// `lungfish-cli fetch sra download --prefer-source ena|ncbi` chooses which
/// archive is tried first, with `ena` the default. `--use-toolkit` keeps
/// its meaning, the SRA Toolkit only with no fallback, so the two flags are
/// refused together. The recorded command carries `--prefer-source ncbi`
/// only when it was chosen, and the provenance records the preference and
/// the source that served the run. ENA is a scripted HTTP client and the
/// toolkit writes recorded fasterq-dump output, so no test reaches the
/// network or spawns a tool.
final class SRADownloadPreferSourceTests: XCTestCase {

    private static let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-cli-prefer-source")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Parsing

    func testTheDefaultIsENA() throws {
        let command = try SRADownloadSubcommand.parse([Self.run])
        XCTAssertNil(command.preferSource)
        XCTAssertEqual(command.sourcePreference, .ena)
    }

    func testPreferSourceTakesENAOrNCBI() throws {
        XCTAssertEqual(try SRADownloadSubcommand.parse([Self.run, "--prefer-source", "ncbi"]).sourcePreference, .ncbi)
        XCTAssertEqual(try SRADownloadSubcommand.parse([Self.run, "--prefer-source", "ena"]).sourcePreference, .ena)
        XCTAssertThrowsError(try SRADownloadSubcommand.parse([Self.run, "--prefer-source", "ddbj"]))
    }

    func testUseToolkitAndPreferSourceAreRefusedTogether() {
        for value in ["ena", "ncbi"] {
            XCTAssertThrowsError(try SRADownloadSubcommand.parse([Self.run, "--use-toolkit", "--prefer-source", value])) { error in
                let message = SRADownloadSubcommand.message(for: error)
                XCTAssertTrue(message.contains("--use-toolkit"), message)
            }
        }
    }

    func testHelpNamesTheTradeOffAndThatUseToolkitHasNoFallback() {
        let help = SRADownloadSubcommand.helpMessage()
        XCTAssertTrue(help.contains("--prefer-source <source>"), help)
        XCTAssertTrue(help.contains("no fallback"), help)
    }

    // MARK: - Running

    func testPreferringNCBIFetchesWithTheToolkitAndRecordsThePreference() async throws {
        let run = try await download(["--prefer-source", "ncbi"], portal: .listsFiles, toolkit: .recorded)

        XCTAssertEqual(run.provenance.parameters["preferredSource"], .string("ncbi"))
        XCTAssertEqual(run.provenance.parameters["requestedStrategy"], .string("sra-toolkit-first"))
        XCTAssertEqual(run.provenance.parameters["downloadSource"], .string("SRA Toolkit"))
        XCTAssertEqual(run.provenance.parameters["condaEnvironment"], .string("managed sra-tools"))
        XCTAssertEqual(run.mirrorRequests, 0)
        let argv = try XCTUnwrap(run.provenance.steps.last?.command)
        XCTAssertEqual(Self.value(after: "--prefer-source", in: argv), "ncbi")

        // The recorded command parses back to the same choice.
        let replayed = try SRADownloadSubcommand.parse(Array(argv.dropFirst(4)))
        XCTAssertEqual(replayed.sourcePreference, .ncbi)
        XCTAssertEqual(replayed.accession, Self.run)
        XCTAssertFalse(replayed.useToolkit)
    }

    func testPreferringNCBIWithoutTheToolkitFallsBackToENAAndRecordsWhy() async throws {
        let run = try await download(["--prefer-source", "ncbi"], portal: .listsFiles, toolkit: .missing)

        XCTAssertEqual(run.provenance.parameters["preferredSource"], .string("ncbi"))
        XCTAssertEqual(run.provenance.parameters["downloadSource"], .string("ENA (SRA Toolkit not installed)"))
        XCTAssertEqual(run.provenance.parameters["selectedStrategy"], .string("ena-fallback"))
        XCTAssertEqual(run.provenance.parameters["condaEnvironment"], .string("none"))
        guard case .string(let message)? = run.provenance.parameters["fallbackMessage"] else {
            return XCTFail("the fallback is recorded")
        }
        XCTAssertTrue(message.contains("not installed"), message)
        XCTAssertEqual(run.mirrorRequests, 2)
    }

    func testTheDefaultRecordsENAAndNoPreferSourceFlag() async throws {
        let run = try await download([], portal: .listsFiles, toolkit: .recorded)

        XCTAssertEqual(run.provenance.parameters["preferredSource"], .string("ena"))
        XCTAssertEqual(run.provenance.parameters["requestedStrategy"], .string("ena-direct"))
        XCTAssertEqual(run.provenance.parameters["downloadSource"], .string("ENA"))
        XCTAssertFalse(try XCTUnwrap(run.provenance.steps.last?.command).contains("--prefer-source"))
    }

    func testUseToolkitKeepsItsMeaning() async throws {
        let run = try await download(["--use-toolkit"], portal: .listsFiles, toolkit: .recorded)

        XCTAssertEqual(run.provenance.parameters["requestedStrategy"], .string("sra-toolkit"))
        XCTAssertEqual(run.provenance.parameters["downloadSource"], .string("SRA Toolkit"))
        XCTAssertEqual(run.provenance.parameters["preferredSource"], .null)
        XCTAssertEqual(run.mirrorRequests, 0)
        let argv = try XCTUnwrap(run.provenance.steps.last?.command)
        XCTAssertTrue(argv.contains("--use-toolkit"))
        XCTAssertFalse(argv.contains("--prefer-source"))

        // Without the toolkit it fails rather than falling back to ENA.
        do {
            _ = try await download(["--use-toolkit"], portal: .listsFiles, toolkit: .missing)
            XCTFail("--use-toolkit must not fall back")
        } catch {}
    }

    // MARK: - Helpers

    private enum Toolkit {
        case recorded
        case missing
    }

    private struct DownloadRun {
        let provenance: WorkflowRun
        let mirrorRequests: Int
    }

    private func download(_ flags: [String], portal: PreferSourcePortal, toolkit: Toolkit) async throws -> DownloadRun {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let client = PreferSourceENAClient(portal: portal, run: Self.run)
        let emptyHome = root.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let runner: SRAToolkitRunner? = toolkit == .recorded ? SRAToolkitRecordedRunner(testFile: #filePath).runner : nil
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            homeDirectoryProvider: { emptyHome },
            toolkitRunner: runner
        )
        let command = try SRADownloadSubcommand.parse([Self.run, "--output-dir", folder.path, "--quiet"] + flags)
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        return DownloadRun(
            provenance: try XCTUnwrap(ProvenanceRecorder.load(from: folder)),
            mirrorRequests: await client.mirrorRequests
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

private enum PreferSourcePortal: Sendable {
    case listsFiles
}

/// Lists the run as two gzip mates on ENA's portal and serves each as an
/// empty gzip stream of the listed size.
private actor PreferSourceENAClient: HTTPClient {
    static let gzipStream = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    let portal: PreferSourcePortal
    let run: String
    private(set) var mirrorRequests = 0

    init(portal: PreferSourcePortal, run: String) {
        self.portal = portal
        self.run = run
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard url.absoluteString.contains("portal/api/filereport") else {
            throw URLError(.cannotFindHost)
        }
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/094/\(run)"
        let payload: [[String: Any]] = [[
            "run_accession": run,
            "library_layout": "PAIRED",
            "fastq_ftp": "\(folder)/\(run)_1.fastq.gz;\(folder)/\(run)_2.fastq.gz",
            "fastq_bytes": "\(Self.gzipStream.count);\(Self.gzipStream.count)",
        ]]
        return (try JSONSerialization.data(withJSONObject: payload), Self.response(url, 200))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        mirrorRequests += 1
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-cli-prefer-source-file-\(UUID().uuidString)")
        try Self.gzipStream.write(to: temporaryURL, options: .atomic)
        return (temporaryURL, Self.response(url, 200))
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
