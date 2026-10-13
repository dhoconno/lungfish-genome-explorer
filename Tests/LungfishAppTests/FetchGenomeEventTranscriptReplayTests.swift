// FetchGenomeEventTranscriptReplayTests.swift - The event transcripts of lungfish-cli fetch genome
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Runs the built `lungfish-cli fetch genome --format json` on the loopback NCBI stand-in and
/// checks the transcripts in `Tests/Fixtures/cli-events/commands/fetch-genome` (Phase 2.10 lane
/// A44). `complete` fetches an assembly and a nucleotide record in one run, and `failed` asks for an
/// assembly the stand-in does not know. The scratch folder is rewritten to `/work` in its plain and
/// its slash-escaped spelling, and nothing else is edited. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1`
/// it writes the transcripts. Otherwise it checks that each run starts and ends as its transcript
/// does, because the number of progress lines follows the download's byte callbacks.
///
/// It launches the built CLI and the managed bgzip and samtools, so its name ends in ReplayTests,
/// which sends it to the integration tier.
final class FetchGenomeEventTranscriptReplayTests: XCTestCase {
    func testACompleteRunNamesEachBundle() async throws {
        try await capture(
            "complete",
            accessions: [NCBIGenomeStandIn.assemblyAccession, NCBIDownloadPinFixtures.genBankAccession],
            exitStatus: 0)
    }

    func testAFailedRunNamesTheAccession() async throws {
        try await capture("failed", accessions: [NCBIGenomeStandIn.unknownAccession], exitStatus: 1)
    }

    private func capture(_ name: String, accessions: [String], exitStatus: Int32) async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-genome-events")
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let work = root.appendingPathComponent("work", isDirectory: true)
        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: ["fetch", "genome"] + accessions + ["--output-dir", work.path, "--format", "json"],
            timeout: .seconds(120))
        XCTAssertEqual(run.status, exitStatus, run.detail)
        let lines = run.stdout.split(separator: "\n").map { Self.normalized(String($0), work: work) }
        let url = CLIEventTranscriptLocation.url(leaf: "fetch genome", name: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, expected.first, "The run starts as \(name).ndjson does")
        XCTAssertEqual(lines.last, expected.last, "The run ends as \(name).ndjson does")
    }

    /// `line` with every spelling of `work` rewritten to `/work`.
    static func normalized(_ line: String, work: URL) -> String {
        let spellings = Set([work.path, work.resolvingSymlinksInPath().path, "/private" + work.path])
            .sorted { $0.count > $1.count }
        var text = line
        for spelling in spellings {
            text = text.replacingOccurrences(of: spelling.replacingOccurrences(of: "/", with: "\\/"), with: "\\/work")
            text = text.replacingOccurrences(of: spelling, with: "/work")
        }
        return text
    }
}

/// Where the transcripts of an events leaf live, as `CLIEventTranscriptCoverageTests` reads them.
enum CLIEventTranscriptLocation {
    static func url(leaf: String, name: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.lastPathComponent != "Tests" { root.deleteLastPathComponent() }
        return root
            .appendingPathComponent("Fixtures/cli-events/commands", isDirectory: true)
            .appendingPathComponent(leaf.split(separator: " ").joined(separator: "-"), isDirectory: true)
            .appendingPathComponent("\(name).ndjson")
    }
}
