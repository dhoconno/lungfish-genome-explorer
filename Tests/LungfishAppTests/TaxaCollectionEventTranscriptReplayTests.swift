// TaxaCollectionEventTranscriptReplayTests.swift - The event transcripts of lungfish-cli extract taxa-collection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// Runs the built `lungfish-cli extract taxa-collection --format json` on the argv of the Extract button of the
/// taxa collections drawer and checks the transcripts in `Tests/Fixtures/cli-events/commands/extract-taxa-collection`
/// (Phase 2.11 lane A66, the transcript fix of landing 19). `complete` extracts Genus A with its children and
/// Species B from the single-end Kraken2 result of `TaxaCollectionFixtures`, and `failed` points at a result folder
/// that does not exist. The scratch folder is rewritten to `/work` in its plain and its slash-escaped spelling,
/// and nothing else is edited. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1` it writes the transcripts. Otherwise it fails
/// when a line of a run differs from its transcript, so the words the Operations row reads cannot drift.
///
/// It runs the managed seqkit and launches the built CLI, so its name ends in ReplayTests, which sends it to the
/// integration tier, and it skips without the tool unless `LUNGFISH_REQUIRE_TOOLS=1`.
@MainActor
final class TaxaCollectionEventTranscriptReplayTests: XCTestCase {
    func testACompleteRunNamesTheFileOfEachTaxon() async throws {
        try await requireSeqkit()
        try await capture("complete", resultFolder: "kraken2-single", exitStatus: 0)
    }

    func testAFailedRunNamesTheMissingResult() async throws {
        try await capture("failed", resultFolder: "kraken2-missing", exitStatus: 3)
    }

    private func capture(_ name: String, resultFolder: String, exitStatus: Int32) async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "taxa-collection-events")
        defer { TestTempDirectory.cleanup(root) }
        let fixtures = try TaxaCollectionFixtures(in: root)
        let collection = TaxaCollectionFixtures.collection
        let result = fixtures.projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(resultFolder, isDirectory: true)
        // The words the Extract button hands the runner, `--format json` included.
        let arguments = ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection,
            resultDirectory: result,
            outputDirectory: result.appendingPathComponent("extracted-\(collection.id)", isDirectory: true))

        let run = await RouteParityHarness.runCLI(cli, arguments: arguments, timeout: .seconds(120))
        XCTAssertEqual(run.status, exitStatus, run.detail)
        let lines = run.stdout.split(separator: "\n").map { FetchGenomeEventTranscriptReplayTests.normalized(String($0), work: root) }
        let url = CLIEventTranscriptLocation.url(leaf: "extract taxa-collection", name: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(
            lines, expected,
            "extract taxa-collection no longer prints its \(name) transcript. If the change is deliberate, run with LUNGFISH_RECAPTURE_CLI_EVENTS=1 and review the diff")
    }

    private func requireSeqkit(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.findTool(.seqkit)
        } catch {
            try ToolAvailability.skipOrFail("Managed seqkit is required: \(error)", file: file, line: line)
        }
    }
}
