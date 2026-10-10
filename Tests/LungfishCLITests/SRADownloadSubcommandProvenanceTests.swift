// SRADownloadSubcommandProvenanceTests.swift - fetch sra download reports and records only the run it fetched
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// `lungfish-cli fetch sra download` writes its reads into `--output-dir`,
/// which can already hold other runs and older files of the same run. After
/// an SRA Toolkit fallback it reports, and records as outputs, only the reads
/// this download wrote, removes the archive `prefetch` added, and records the
/// environment that ran, as the window's import does. ENA is a mock HTTP
/// client and the toolkit is a scripted runner, so no test reaches the
/// network or spawns a tool.
final class SRADownloadSubcommandProvenanceTests: XCTestCase {

    func testToolkitFallbackRecordsOnlyThisRunsReadsAndTheSRAToolsEnvironment() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-cli-download")
        defer { TestTempDirectory.cleanup(folder) }
        // Another run downloaded here earlier, and a mate of this run from an
        // earlier ENA download.
        let leftovers = ["SRR100_1.fastq", "SRR100_2.fastq", "SRR200_2.fastq.gz"]
        for name in leftovers {
            try Data("@\(name)\n".utf8).write(to: folder.appendingPathComponent(name))
        }

        let run = try await Self.download(into: folder, portal: .outage)

        XCTAssertEqual(run.parameters["downloadSource"], .string("SRA Toolkit"))
        XCTAssertEqual(run.parameters["condaEnvironment"], .string("managed sra-tools"))
        let downloadStep = try XCTUnwrap(run.steps.last)
        XCTAssertEqual(
            downloadStep.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["SRR200_1.fastq", "SRR200_2.fastq"],
            "the command reports only the reads this download wrote"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("SRR200").path),
            "the archive prefetch added is removed once fasterq-dump succeeds"
        )
        for name in leftovers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
        }
    }

    func testENADownloadRecordsNoCondaEnvironment() async throws {
        let folder = try TestTempDirectory.make(prefix: "sra-cli-download")
        defer { TestTempDirectory.cleanup(folder) }

        let run = try await Self.download(into: folder, portal: .pairedRun)

        XCTAssertEqual(run.parameters["downloadSource"], .string("ENA"))
        XCTAssertEqual(run.parameters["condaEnvironment"], .string("none"))
        XCTAssertEqual(
            try XCTUnwrap(run.steps.last).outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["SRR200_1.fastq.gz", "SRR200_2.fastq.gz"]
        )
    }

    // MARK: - Helpers

    /// Runs `fetch sra download SRR200` into `folder` and returns the
    /// provenance it wrote there.
    static func download(into folder: URL, portal: ScriptedENAClient.Portal) async throws -> WorkflowRun {
        let client = ScriptedENAClient(portal: portal)
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            toolkitRunner: toolkitRunner()
        )
        let command = try SRADownloadSubcommand.parse(["SRR200", "--output-dir", folder.path, "--quiet"])
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        return try XCTUnwrap(ProvenanceRecorder.load(from: folder))
    }

    /// A toolkit whose `prefetch` writes `<output>/SRR200/SRR200.sra` and
    /// whose `fasterq-dump` writes the run's two mates, as the real tools do.
    private static func toolkitRunner() -> SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { executable, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "-O"))
            let outputDirectory = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                let archiveFolder = outputDirectory.appendingPathComponent("SRR200", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: archiveFolder.appendingPathComponent("SRR200.sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            for mate in ["SRR200_1.fastq", "SRR200_2.fastq"] {
                try Data("@\(mate).1\nACGT\n+\nIIII\n".utf8).write(to: outputDirectory.appendingPathComponent(mate))
            }
            return SRAToolkitRunner.Result(exitCode: 0)
        }
    }
}

/// Answers ENA's portal as the test scripts it and serves each mirror file
/// as an empty gzip stream of the size the portal lists.
actor ScriptedENAClient: HTTPClient {
    enum Portal: Sendable {
        /// ENA's portal answers HTTP 500 with an error page.
        case outage
        /// ENA's portal lists SRR200 as a paired run with two mates.
        case pairedRun
    }

    /// An empty gzip stream, which passes ENA's download check.
    static let gzipStream = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    let portal: Portal

    init(portal: Portal) {
        self.portal = portal
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard url.absoluteString.contains("portal/api/filereport") else {
            throw URLError(.cannotFindHost)
        }
        switch portal {
        case .outage:
            return (Data("<html><body>Internal Server Error</body></html>".utf8), Self.response(url, 500))
        case .pairedRun:
            let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/SRR200"
            let payload: [[String: Any]] = [[
                "run_accession": "SRR200",
                "library_layout": "PAIRED",
                "fastq_ftp": "\(folder)/SRR200_1.fastq.gz;\(folder)/SRR200_2.fastq.gz",
                "fastq_bytes": "\(Self.gzipStream.count);\(Self.gzipStream.count)",
            ]]
            return (try JSONSerialization.data(withJSONObject: payload), Self.response(url, 200))
        }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-cli-download-file-\(UUID().uuidString)")
        try Self.gzipStream.write(to: temporaryURL, options: .atomic)
        return (temporaryURL, Self.response(url, 200))
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
