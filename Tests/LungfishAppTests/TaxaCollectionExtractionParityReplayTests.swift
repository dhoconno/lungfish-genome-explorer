// TaxaCollectionExtractionParityReplayTests.swift - The collection extraction in process against extract taxa-collection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66 M2, on lane Q30's harness (decisions C4 and C5 of 2.10 and G1). The Extract
// button of the taxa collections drawer ran `TaxonomyExtractionPipeline.extractBatch` in the app and
// recorded no command. It now launches `lungfish-cli extract taxa-collection` on `CLIBundleBuildRunner`
// and records that command. Each case runs on three sides that start as copies of one project with a
// single-end and a paired Kraken2 result.
//
// - Side A was the in-process route at the base, `extractBatch` on the loaded result. It retired with
//   the old engine in Phase 2.12 lane 12.11 M3, so it no longer runs, and the class compares C against C'.
// - Side C is the CLI route, the begin helper the viewer calls and `CLIBundleBuildRunner`, which launches
//   the built `lungfish-cli` on the argv of `ViewerViewController.taxaCollectionExtractionArguments`.
//   Its row records the command.
// - Side C' is the harness's replay of that command.
//
// C against C' declares nothing. The cases cover a taxon with children (BIO 2), a paired
// result whose taxa keep their mates together (BIO 3) and taxa the result cannot give, skipped and not
// counted. The last test drives the viewer's Extract button itself.
//
// It runs the managed seqkit and launches the built lungfish-cli, so its name ends in ReplayTests, which
// sends it to the integration tier, and it skips without the tool unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxaCollectionExtractionParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// Genus A with its children and Species B alone over a single-end result (BIO 2).
        case singleEndWithChildren
        /// The same collection over a paired result, each taxon's mates together in one file (BIO 3).
        case pairedMates
        /// Two taxa the result cannot give, skipped on every side, and one it can.
        case skippedTaxa
    }

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!
    /// The GUI side's result view saves its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "taxa-collection-parity")
        hostDefaults = HostDefaultsRestorer(keysContaining: scratch.lastPathComponent)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        hostDefaults?.restore()
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testASingleEndResultExtractsWhatTheInProcessBatchExtracted() async throws {
        try await requireSeqkit()
        try await assertCase(.singleEndWithChildren, detail: "Extracted 2 taxa from A66 genus and B")
    }

    func testAPairedResultExtractsWhatTheInProcessBatchExtracted() async throws {
        try await requireSeqkit()
        try await assertCase(.pairedMates, detail: "Extracted 2 taxa from A66 genus and B")
    }

    func testTaxaTheResultCannotGiveAreSkippedOnEverySide() async throws {
        try await requireSeqkit()
        try await assertCase(.skippedTaxa, detail: "Extracted 1 taxa from A66 skips")
    }

    /// The folder's root record names the command the row recorded and every file the run wrote (review
    /// of A66, ARCH checks 2 and 3). The pipeline saves one record a taxon, so without the leaf's own
    /// record the folder's root record would name the last taxon's step, a command the row did not run.
    func testTheRootRecordNamesTheCommandTheRowRecorded() async throws {
        try await requireSeqkit()
        for parityCase in [Case.singleEndWithChildren, .pairedMates] {
            let root = scratch.appendingPathComponent("record-\(parityCase.rawValue)", isDirectory: true)
            _ = try TaxaCollectionFixtures(in: root)
            let outcome = await sideC(root, parityCase)
            XCTAssertEqual(outcome.end, .completed, "\(parityCase): \(outcome.detail)")
            let command = try XCTUnwrap(outcome.recordedCommand, "\(parityCase): the row recorded no command")
            let rowWords = try RouteParityHarness.arguments(ofLine: command)
            let folder = Self.setup(root, parityCase).outputDirectory

            let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "\(parityCase): the folder holds no record")
            XCTAssertEqual(record.status, .completed, "\(parityCase): the root record reads completed")
            XCTAssertEqual(Array(record.argv.dropFirst()), rowWords, "\(parityCase): the root record names the command the row recorded")
            let recorded = record.outputs.map { URL(fileURLWithPath: $0.path, relativeTo: folder).standardizedFileURL }
            XCTAssertFalse(recorded.isEmpty, "\(parityCase): the root record names no output")
            for output in recorded {
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(parityCase): \(output.path) is recorded but missing")
            }
            let written = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".fastq.gz") })
            XCTAssertFalse(written.isEmpty, "\(parityCase): the run wrote no file")
            XCTAssertEqual(
                written.subtracting(Set(recorded.map(\.lastPathComponent))), [],
                "\(parityCase): every file of the folder is named in the root record"
            )
        }
    }

    /// Side A, `extractBatch`, retired with the old engine in lane 12.11 M3 (the review's fix 9). The
    /// harness still runs a side A, so it is this outcome, and the class compares C against C' alone,
    /// with nothing declared. The two differences A had, both closed by the retirement of side A, went
    /// with it.
    private static let retiredSideA = RouteParitySideOutcome(end: .completed, detail: "not run, extractBatch retired in 2.12 lane 12.11")

    private func assertCase(_ parityCase: Case, detail: String) async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in _ = try TaxaCollectionFixtures(in: root) },
            sideA: { _ in Self.retiredSideA },
            sideC: { root in await self.sideC(root, parityCase) }
        )
        let differences = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(differences.map { "\($0)" }, in: "\(parityCase), C against C'")
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(runs.c.outcome.detail, detail, "the row's complete words")
    }

    // MARK: - The sides

    /// What the viewer hands both routes for `parityCase` in `root`.
    private struct Setup {
        let resultFolder: URL
        let collection: TaxaCollection
        var outputDirectory: URL {
            resultFolder.appendingPathComponent("extracted-\(collection.id)", isDirectory: true)
        }
    }

    private static func setup(_ root: URL, _ parityCase: Case) -> Setup {
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        switch parityCase {
        case .singleEndWithChildren:
            return Setup(resultFolder: analyses.appendingPathComponent("kraken2-single", isDirectory: true), collection: TaxaCollectionFixtures.collection)
        case .pairedMates:
            return Setup(resultFolder: analyses.appendingPathComponent("kraken2-paired", isDirectory: true), collection: TaxaCollectionFixtures.collection)
        case .skippedTaxa:
            return Setup(resultFolder: analyses.appendingPathComponent("kraken2-single", isDirectory: true), collection: TaxaCollectionFixtures.skippingCollection)
        }
    }

    /// Side C. The begin helper the viewer calls, and the runner on the argv the viewer hands it, which
    /// launches the built CLI. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: cli)
        do {
            let setup = Self.setup(root, parityCase)
            let arguments = ViewerViewController.taxaCollectionExtractionArguments(
                collection: setup.collection,
                resultDirectory: setup.resultFolder,
                outputDirectory: setup.outputDirectory
            )
            var operationID: UUID?
            ViewerViewController.beginTaxaCollectionExtractionOperation(
                collection: setup.collection, arguments: arguments, routeContext: nil, reporter: reporter
            ) { operationID = $0 }
            let id = try XCTUnwrap(operationID, "the row did not start")
            let result = try await runner.run(arguments: arguments, operationID: id)
            return RouteParitySideOutcome(
                end: .completed, detail: result.message ?? "", recordedCommand: reporter.items.first?.cliCommand
            )
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    // MARK: - The viewer's Extract button

    func testTheExtractButtonRunsTheCommandAndEndsItsRowWithTheTaxaCount() async throws {
        try await requireSeqkit()
        // The button launches the bundled CLI, which a test points at the built one.
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        addTeardownBlock { unsetenv("LUNGFISH_CLI_PATH") }
        let fixtures = try TaxaCollectionFixtures(in: scratch.appendingPathComponent("button", isDirectory: true))
        let collection = TaxaCollectionFixtures.collection
        let result = try ClassificationResult.load(from: fixtures.singleEnd)
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayTaxonomyResult(result)
        let taxonomy = try XCTUnwrap(viewer.children.compactMap { $0 as? TaxonomyViewController }.first)
        let before = Set(OperationCenter.shared.items.map(\.id))

        taxonomy.onBatchExtract?(collection, result)

        let title = "Extract \(collection.name)"
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if let row = OperationCenter.shared.items.first(where: { !before.contains($0.id) && $0.title == title }), !row.state.isActive {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let row = try XCTUnwrap(OperationCenter.shared.items.first { !before.contains($0.id) && $0.title == title })
        XCTAssertEqual(row.state, .completed, "detail: \(row.detail)")
        XCTAssertEqual(row.detail, "Extracted 2 taxa from A66 genus and B")
        XCTAssertEqual(row.cliCommand?.hasPrefix("lungfish-cli extract taxa-collection --result "), true, row.cliCommand ?? "no command")
        let folder = result.config.outputDirectory.appendingPathComponent("extracted-\(collection.id)", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".fastq.gz") }.sorted(),
            ["Genus_A_taxid10.fastq.gz", "Species_B_taxid20.fastq.gz"]
        )
    }

    private func requireSeqkit(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.findTool(.seqkit)
        } catch {
            try ToolAvailability.skipOrFail("Managed seqkit is required: \(error)", file: file, line: line)
        }
    }
}
