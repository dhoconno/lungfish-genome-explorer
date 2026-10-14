// FetchNCBIEventTranscriptReplayTests.swift - The event transcripts of lungfish-cli fetch ncbi --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Runs the built `lungfish-cli fetch ncbi --bundle --format json` on the loopback NCBI stand-in
/// and checks the transcripts in `Tests/Fixtures/cli-events/commands/fetch-ncbi` (Phase 2.10 lane
/// A45). `complete` fetches the stand-in's two records in one run, and `failed` asks for a record the
/// stand-in does not know. The scratch folder is rewritten to `/work`, as the transcripts of `fetch
/// genome` are. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1` it writes the transcripts. Otherwise it checks
/// that each run starts and ends as its transcript does, because the number of progress lines follows
/// the builder's stages.
///
/// It launches the built CLI and the managed bgzip and samtools, so its name ends in ReplayTests,
/// which sends it to the integration tier.
final class FetchNCBIEventTranscriptReplayTests: XCTestCase {
    func testACompleteRunNamesEachBundle() async throws {
        try await capture(
            "complete",
            accessions: [NCBIDownloadPinFixtures.genBankAccession, NCBIGenomeStandIn.recordWithoutGFF3Accession],
            exitStatus: 0)
    }

    func testAFailedRunNamesTheAccession() async throws {
        try await capture("failed", accessions: ["ZZ999999.1"], exitStatus: 1)
    }

    private func capture(_ name: String, accessions: [String], exitStatus: Int32) async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-ncbi-events")
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
            arguments: ["fetch", "ncbi"] + accessions + ["--bundle", "--output-dir", work.path, "--format", "json"],
            timeout: .seconds(120))
        XCTAssertEqual(run.status, exitStatus, run.detail)
        let lines = run.stdout.split(separator: "\n").map { FetchGenomeEventTranscriptReplayTests.normalized(String($0), work: work) }
        let url = CLIEventTranscriptLocation.url(leaf: "fetch ncbi", name: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, expected.first, "The run starts as \(name).ndjson does")
        XCTAssertEqual(lines.last, expected.last, "The run ends as \(name).ndjson does")
        if exitStatus != 0 {
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [])
            XCTAssertEqual(leftovers.filter { $0.hasSuffix(".lungfishref") || $0.hasPrefix(".fetch-ncbi-") }, [], "a failed run leaves nothing")
        }
    }
}
