// ReferenceBundleMergeParityReplayTests.swift - The reference bundle merge in the app against bundle merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M2, plan decisions C4 and C5 of 2.10 and G1, on lane Q30's harness. The sidebar merges
// two reference bundles, each with a sequence and a gene track, into a new bundle in the project. Each case
// runs on three sides that start as copies of one project.
//
// - Side A is the in-process merge, `ReferenceBundleMergeService.merge(...)`, which the sidebar ran in the app.
// - Side C is the CLI route, `ReferenceBundleMergeRoute.merge` and `CLIBundleBuildRunner`, which launches the
//   built `lungfish-cli bundle merge`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C and C against C' declare nothing (C4). The class also checks that the stage is gone and that
// no record of the published bundle names it.
//
// It runs the managed bgzip and samtools faidx and launches the built lungfish-cli, so its name ends in
// ReplayTests, which sends it to the integration tier, and it skips without the tools unless
// `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReferenceBundleMergeParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case twoBundles
    }

    /// The differences of A against C, none.
    static let declared: [RouteParityDeclaredDifference<Case>] = []

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "reference-merge-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheMergeRowBuildsWhatTheInProcessMergeBuilt() async throws {
        try await requireTools()
        let result = try await harness.assertParity(
            Case.twoBundles,
            declared: Self.declared,
            in: scratch.appendingPathComponent(Case.twoBundles.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root) }
        )
        for run in [result.runs.a, result.runs.c, result.runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.a.outcome.detail, "Merged 2 reference bundles", "the row's complete words")
        XCTAssertEqual(result.runs.c.outcome.detail, "Merged 2 reference bundles", "the row's complete words")
        for run in result.runs.all {
            let project = run.root.appendingPathComponent("Project.lungfish", isDirectory: true)
            let temp = project.appendingPathComponent(".tmp", isDirectory: true)
            let stages = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
                .filter { $0.hasPrefix("reference-merge-") }
            XCTAssertEqual(stages, [], "side \(run.side): the stage is removed")
            let bundle = project.appendingPathComponent("Merged.lungfishref", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "side \(run.side): the bundle is published")
            for file in Self.recordFiles(in: bundle) {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertNil(
                    text.range(of: #"reference-merge-[A-Za-z0-9]+\\?/stage"#, options: .regularExpression),
                    "side \(run.side): \(file.lastPathComponent) names the stage"
                )
            }
        }
    }

    // MARK: - The sides

    private static func sources(_ root: URL) -> (urls: [URL], project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        return (["Alpha", "Beta"].map { project.appendingPathComponent("\($0).lungfishref", isDirectory: true) }, project)
    }

    /// Side A. The service in process, as the sidebar ran it before the route moved. It is given the words the
    /// route starts the command with, as the leaf is by its process, so both records name the same command
    /// (2.12 lane 12.14, A49-REC). Without them the record states the equivalent command, which
    /// `ReferenceBundleMergeRecordConformanceTests` pins.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let (urls, project) = Self.sources(root)
        do {
            let started = [harness.cliBinary.path] + ReferenceBundleMergeRoute.arguments(
                sourceBundleURLs: urls, outputDirectory: project, bundleName: "Merged"
            )
            _ = try await ReferenceBundleMergeService.runDetached(
                sourceBundleURLs: urls, outputDirectory: project, bundleName: "Merged",
                provenanceWriter: .live, reporter: .none, observedArguments: started
            )
            return RouteParitySideOutcome(end: .completed, detail: "Merged \(urls.count) reference bundles")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The route the sidebar calls, on the runner that launches the built CLI. It returns the row's
    /// command, which side C' replays.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let (urls, project) = Self.sources(root)
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        do {
            var message = ""
            _ = try await ReferenceBundleMergeRoute.merge(
                sourceBundleURLs: urls, outputDirectory: project, bundleName: "Merged", reporter: reporter
            ) { arguments, id in
                let result = try await runner.run(arguments: arguments, operationID: id)
                message = result.message ?? ""
                return ReferenceBundleMergeRoute.Run(outputs: result.outputs, message: result.message)
            }
            return RouteParitySideOutcome(end: .completed, detail: message, recordedCommand: reporter.items.first?.cliCommand)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    // MARK: - Fixture

    /// A project with two source bundles, each with a sequence of 20 bases and a gene track.
    private static func writeFixture(_ root: URL) throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        _ = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        _ = try ReferenceMergeFixture.writeSource(
            named: "Beta", sequence: "chrB", bases: "TTGGCCAATTGGCCAATTGG", gene: "geneB", in: project, inputs: inputs
        )
    }

    /// The JSON records of a bundle, its envelope and the files of its provenance folder.
    nonisolated private static func recordFiles(in bundle: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(ProvenanceWriter.provenanceFilename) }
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }
}
