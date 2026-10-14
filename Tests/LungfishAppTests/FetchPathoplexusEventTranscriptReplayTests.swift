// FetchPathoplexusEventTranscriptReplayTests.swift - The event transcripts of lungfish-cli fetch pathoplexus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Runs the built `lungfish-cli fetch pathoplexus --format json` on the loopback Pathoplexus and NCBI
/// stand-ins and checks the transcripts in `Tests/Fixtures/cli-events/commands/fetch-pathoplexus`
/// (Phase 2.10 lane A45 M2). `complete` fetches the stand-in's three open records in one run, one for
/// each way a record builds (an INSDC accession, no INSDC accession, an INSDC accession GenBank cannot
/// serve), and `failed` asks for a restricted record. The scratch folder is rewritten to `/work`, as the
/// transcripts of `fetch genome` and `fetch ncbi` are. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1` it writes
/// the transcripts. Otherwise it checks that each run starts and ends as its transcript does, because
/// the number of progress lines follows the builder's stages.
///
/// It launches the built CLI and the managed bgzip and samtools, so its name ends in ReplayTests,
/// which sends it to the integration tier.
final class FetchPathoplexusEventTranscriptReplayTests: XCTestCase {
    func testACompleteRunNamesEachBundle() async throws {
        try await capture(
            "complete",
            accessions: [
                PathoplexusLAPISStandIn.openWithINSDC, PathoplexusLAPISStandIn.openNoINSDC,
                PathoplexusLAPISStandIn.openINSDCUnavailable,
            ],
            exitStatus: 0)
    }

    func testARestrictedRecordFailsTheRunWithTheRefusal() async throws {
        try await capture("failed", accessions: [PathoplexusLAPISStandIn.restricted], exitStatus: 1)
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
        let root = try TestTempDirectory.make(prefix: "fetch-pathoplexus-events")
        defer { TestTempDirectory.cleanup(root) }
        let ncbi = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { ncbi.stop() }
        let lapis = try PathoplexusLAPISStandIn.start()
        defer { lapis.stop() }

        let work = root.appendingPathComponent("work", isDirectory: true)
        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: ["fetch", "pathoplexus"] + accessions
                + ["--organism", PathoplexusLAPISStandIn.organism, "--output-dir", work.path, "--format", "json"],
            timeout: .seconds(120),
            environment: [
                NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
                "NCBI_API_KEY": "",
            ])
        XCTAssertEqual(run.status, exitStatus, run.detail)
        let lines = run.stdout.split(separator: "\n").map { FetchGenomeEventTranscriptReplayTests.normalized(String($0), work: work) }
        // The bar of a batch only moves forward, also when a record falls back to the Pathoplexus FASTA.
        let fractions = lines.compactMap { line -> Double? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "progress" else { return nil }
            return object["progress"] as? Double
        }
        XCTAssertEqual(fractions, fractions.sorted(), "progress falls back in \(name)")
        let url = CLIEventTranscriptLocation.url(leaf: "fetch pathoplexus", name: name)
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
            XCTAssertEqual(
                leftovers.filter { $0.hasSuffix(".lungfishref") || $0.hasPrefix(".fetch-pathoplexus-") }, [], "a failed run leaves nothing")
        }
    }
}
