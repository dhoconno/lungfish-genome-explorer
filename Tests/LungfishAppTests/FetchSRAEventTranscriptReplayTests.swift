// FetchSRAEventTranscriptReplayTests.swift - The event transcripts of lungfish-cli fetch sra download --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Runs the built `lungfish-cli fetch sra download --bundle --format json` with the SRA Toolkit stand-in
/// scripts and checks the transcripts in `Tests/Fixtures/cli-events/commands/fetch-sra-download` (Phase 2.10
/// lane A45 M3). `complete` imports the recorded single-end run into a project of the scratch folder, and
/// `failed` asks for a run the toolkit cannot serve. The scratch folder is rewritten to `/work`, as the
/// transcripts of `fetch genome` and `fetch ncbi` are. NCBI's run info is asked at an origin that answers
/// nothing, so the run reaches no network. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1` it writes the
/// transcripts. Otherwise it checks that each run starts and ends as its transcript does, because the
/// number of progress lines follows the importer's stages.
///
/// It launches the built CLI and the managed tools of the import, so its name ends in ReplayTests, which
/// sends it to the integration tier.
final class FetchSRAEventTranscriptReplayTests: XCTestCase {
    func testACompleteRunNamesTheBundleItPublished() async throws {
        try await capture("complete", accession: SRAToolkitRecordedRunner.singleEndRun, exitStatus: 0)
    }

    func testARunTheToolkitCannotServeEndsWithOneFailedLine() async throws {
        try await capture("failed", accession: "SRR9000001", exitStatus: 1)
    }

    private func capture(_ name: String, accession: String, exitStatus: Int32) async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-sra-events")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let scripts = root.appendingPathComponent("toolkit", isDirectory: true)
        try SRAToolkitStandInScripts.write(
            into: scripts, fixtures: SRAToolkitStandInScripts.fixturesFolder(testFile: #filePath))

        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: [
                "fetch", "sra", "download", accession, "--bundle", "--project", project.path, "--use-toolkit",
                "--platform", "illumina", "--compression", "fast", "--no-optimize-storage", "--format", "json",
            ],
            timeout: .seconds(120),
            environment: [
                SRAToolkitStandInScripts.variable: scripts.path,
                NCBIServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                "NCBI_API_KEY": "",
            ])
        XCTAssertEqual(run.status, exitStatus, run.detail)
        let lines = run.stdout.split(separator: "\n").map { FetchGenomeEventTranscriptReplayTests.normalized(String($0), work: root) }
        // The bar only moves forward, from the download into the import.
        let fractions = lines.compactMap { line -> Double? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "progress" else { return nil }
            return object["progress"] as? Double
        }
        XCTAssertEqual(fractions, fractions.sorted(), "progress falls back in \(name)")
        let url = CLIEventTranscriptLocation.url(leaf: "fetch sra download", name: name)
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
            let staging = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? []
            XCTAssertEqual(staging.filter { $0.hasPrefix("fetch-sra-") }, [], "a failed run leaves no staging folder")
            let bundles = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)) ?? []
            XCTAssertEqual(bundles, [], "a failed run publishes no bundle")
        }
    }
}
