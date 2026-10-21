// PrimerExportCLIGUIParityReplayTests.swift - The two primer exports in the app against their CLI leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M3, ARCH ruling on the export shape 1.7 and 1.6, on lane Q30's harness. Each case runs on three
// sides that start as copies of one saved primer analysis.
//
// - Side A is the in-app writer, `PrimerOrderExportService` or `PrimerAnalysisSelectionExportService` called in the test
//   process with the argv the app passes (the canonical argv of the row's invocation), as `exportDisplayedPrimerOrder`
//   and `exportPrimerAnalysisSelection` ran them before the leaf.
// - Side C is the app's begin helper with the invocation the app builds. It begins the row and runs the built
//   `lungfish-cli primers analysis export-order` or `export-selection` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C and C against C' declare nothing, so the in-process writer goes in the lane with no key (R-A1, C4). The
// cancel runs through the real transport. The leaf holds after it staged its folder, on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the folder nor its hidden staging folder is
// left (ARCH ruling 1.6, X14). The suite launches the built lungfish-cli, so its name ends in ReplayTests.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class ReloadCalls {
    var count = 0
}

@MainActor
final class PrimerExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable, CaseIterable {
        case orderCandidatePair
        case selectionPrimerFASTA
        case selectionReferenceAmplicon
    }

    /// What one side runs for a case in its root.
    struct Plan {
        enum Writer {
            case order(selection: PrimerOrderSelection, metadata: PrimerOrderMetadata)
            case selection(analysisURL: URL, selection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind)
        }
        let invocation: ViewerExportInvocation
        let title: String
        let detail: String
        let output: URL
        let writer: Writer
    }

    private var scratch: URL!
    private var harness: RouteParityHarness!
    /// The canonical argv side A passed to the in-app writer.
    private var argvA: [String] = []

    override func setUpWithError() throws {
        scratch = try PrimerAnalysisExportParityFixtures.physical(TestTempDirectory.make(prefix: "primer-export-parity"))
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testAnOrderMatchesOnAllThreeSides() async throws {
        let runs = try await assertParity(.orderCandidatePair)
        let record = try PrimerOrderExportService.loadSnapshot(from: Self.output(.orderCandidatePair, in: runs.c.root)).provenance
        XCTAssertEqual(
            Array(record.argv.prefix(4)), [CLICommandIdentity.executableName, "primers", "analysis", "export-order"])
    }

    func testAPrimerFASTABundleMatchesOnAllThreeSides() async throws {
        let runs = try await assertParity(.selectionPrimerFASTA)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: Self.output(.selectionPrimerFASTA, in: runs.c.root)))
        XCTAssertEqual(record.workflowName, "lungfish.primer-analysis.selection-export")
    }

    func testAReferenceAmpliconMatchesOnAllThreeSides() async throws {
        try await assertParity(.selectionReferenceAmplicon)
    }

    func testACancelledOrderExits125AndLeavesNeitherFolderNorStaging() async throws {
        try await assertCancel(.orderCandidatePair)
    }

    func testACancelledSelectionExits125AndLeavesNeitherFolderNorStaging() async throws {
        try await assertCancel(.selectionPrimerFASTA)
    }
}

// MARK: - The sides and the comparison

extension PrimerExportCLIGUIParityReplayTests {
    static let analysisNames: [Case: String] = [
        .orderCandidatePair: "fixture.lungfishprimeranalysis",
        .selectionPrimerFASTA: "source.lungfishprimeranalysis",
        .selectionReferenceAmplicon: "source.lungfishprimeranalysis",
    ]

    /// The folder each side writes, in its root.
    static func output(_ item: Case, in root: URL) -> URL {
        switch item {
        case .orderCandidatePair: root.appendingPathComponent("order", isDirectory: true)
        case .selectionPrimerFASTA: root.appendingPathComponent("pool.lungfishref", isDirectory: true)
        case .selectionReferenceAmplicon: root.appendingPathComponent("amplicon.lungfishref", isDirectory: true)
        }
    }

    /// Builds the saved analysis in a folder beside `root` and copies it in. The harness copies root A to roots C and C',
    /// and a bundle built in root A records root A's path, which the export would copy into the folders of the other two
    /// sides and which the harness reads as a side naming another side's root. Built in a neutral folder, the bundle
    /// names no side's root.
    static func makeFixture(_ item: Case, in root: URL) throws {
        // The folder name must not start with a side folder name, since the harness reads a path that does as that side's root.
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("fixture-source-" + root.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bundle: URL
        switch item {
        case .orderCandidatePair: bundle = try PrimerAnalysisExportParityFixtures.primer3(in: source, pairCount: 2)
        case .selectionPrimerFASTA, .selectionReferenceAmplicon: bundle = try PrimerAnalysisExportParityFixtures.primalScheme(in: source)
        }
        try FileManager.default.copyItem(at: bundle, to: root.appendingPathComponent(bundle.lastPathComponent, isDirectory: true))
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The invocation the app builds for the case in `root`, with the title and detail of its row.
    func plan(_ item: Case, in root: URL) throws -> Plan {
        let bundle = root.appendingPathComponent(Self.analysisNames[item] ?? "", isDirectory: true)
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: bundle)
        let output = Self.output(item, in: root)
        switch item {
        case .orderCandidatePair:
            let pairID = try XCTUnwrap(snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id).last)
            let selection = try PrimerOrderExportService.captureSelection(
                snapshot: snapshot, scope: .primer3CandidatePairs(includedPairIDs: [pairID]))
            let metadata = PrimerOrderMetadata(name: "Pair order", requestedBy: "Bench", notes: "Rush")
            return Plan(
                invocation: PrimerOrderExport.invocation(
                    analysisURL: bundle, selection: selection, metadata: metadata, outputURL: output),
                title: "Export Candidate Pairs", detail: "Verifying 1 candidate oligos…", output: output,
                writer: .order(selection: selection, metadata: metadata))
        case .selectionPrimerFASTA:
            let target = try XCTUnwrap(snapshot.designReview.first)
            return selectionPlan(
                bundle, .pool(sourceResultID: target.sourceResultID, pool: 1), .primerFASTA, output, "Save Primer FASTA Bundle")
        case .selectionReferenceAmplicon:
            let target = try XCTUnwrap(snapshot.designReview.first)
            let amplicon = try XCTUnwrap(target.intervals.first)
            return selectionPlan(
                bundle, .amplicon(targetID: target.id, ampliconID: amplicon.id), .referenceAmplicon, output,
                "Extract Reference Amplicon")
        }
    }

    private func selectionPlan(
        _ bundle: URL, _ selection: PrimerAnalysisExportSelection, _ kind: PrimerAnalysisExportKind, _ output: URL,
        _ title: String
    ) -> Plan {
        Plan(
            invocation: PrimerSelectionExport.invocation(
                analysisURL: bundle, selection: selection, kind: kind, outputURL: output),
            title: title, detail: "Verifying saved primer analysis…", output: output,
            writer: .selection(analysisURL: bundle, selection: selection, kind: kind))
    }

    /// Side A. The in-app writer the actions ran before the leaf, with the argv the app passed.
    private func sideA(_ item: Case, _ root: URL) async throws -> RouteParitySideOutcome {
        let plan = try plan(item, in: root)
        argvA = plan.invocation.canonicalArgv()
        do {
            switch plan.writer {
            case .order(let selection, let metadata):
                _ = try await PrimerOrderExportService().export(
                    selection: selection, metadata: metadata, destinationURL: plan.output,
                    invocationArgv: plan.invocation.canonicalArgv())
            case .selection(let analysisURL, let selection, let kind):
                _ = try await PrimerAnalysisSelectionExportService().export(
                    analysisURL: analysisURL, selection: selection, kind: kind, destinationURL: plan.output,
                    invocationArgv: plan.invocation.canonicalArgv())
            }
            return RouteParitySideOutcome(end: .completed, detail: "Saved in the project's Analyses folder.")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    private func begin(
        _ plan: Plan, in root: URL, environment: [String: String] = [:], reloads: ReloadCalls
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let route = OperationRouteContext(projectURL: root, windowStateScopeID: UUID())
        let runner = CLIViewerExportRunner(cliURLOverride: harness.cliBinary)
        switch plan.writer {
        case .order:
            return MainSplitViewController.beginPrimerOrderExportOperation(
                title: plan.title, detail: plan.detail, invocation: plan.invocation, routeContext: route, runner: runner,
                environmentAdditions: environment
            ) { reloads.count += 1 }
        case .selection:
            return MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
                title: plan.title, invocation: plan.invocation, routeContext: route, runner: runner,
                environmentAdditions: environment
            ) { reloads.count += 1 }
        }
    }

    /// Side C. The app's begin helper, which runs the built CLI behind the row on the shared runner.
    private func sideC(_ item: Case, _ root: URL, reloads: ReloadCalls) async throws -> RouteParitySideOutcome {
        let plan = try plan(item, in: root)
        guard let begun = begin(plan, in: root, reloads: reloads) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let row = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(row?.state, .completed)
            XCTAssertEqual(row?.detail, "Saved in the project's Analyses folder.")
            return RouteParitySideOutcome(end: .completed, detail: row?.detail ?? "no row", recordedCommand: row?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: row?.detail ?? "no row", recordedCommand: row?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: row?.cliCommand)
        }
    }

    /// The argv the folder's record names.
    private func recordedArgv(_ item: Case, in root: URL) throws -> [String] {
        let folder = Self.output(item, in: root)
        if item == .orderCandidatePair {
            return try PrimerOrderExportService.loadSnapshot(from: folder).provenance.argv
        }
        return try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder)).argv
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming another's
    /// root, A against C and C against C' differ in nothing, the sidebar reloads once, and each record names the command
    /// its side ran.
    @discardableResult
    private func assertParity(_ item: Case) async throws -> RouteParityRuns {
        let reloads = ReloadCalls()
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(item.rawValue, isDirectory: true),
            fixture: { root in try Self.makeFixture(item, in: root) },
            sideA: { root in try await self.sideA(item, root) },
            sideC: { root in try await self.sideC(item, root, reloads: reloads) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        // The contract's own check (13.43-M3 review Fix 1). It fails a side that names another side's root, any C
        // against C' difference, any A against C difference and any whole-file difference, and it dumps the case under
        // LUNGFISH_PARITY_DUMP. The class declares nothing, so every difference must be a contract mask.
        let result = try harness.evaluate(item, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: item.rawValue)
        XCTAssertEqual(reloads.count, 1, "the sidebar reloads once, after the leaf wrote the folder")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(
            try recordedArgv(item, in: runs.c.root), [CLICommandIdentity.executableName] + rowArguments,
            "the record's argv is the row's command")
        XCTAssertEqual(
            try recordedArgv(item, in: runs.a.root), argvA,
            "the in-app writer recorded the canonical argv of the invocation, built before the folder existed")
        return runs
    }

    private func assertNothingLeft(_ output: URL, in root: URL, _ message: String) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(message): no output folder")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".primer-") }
        XCTAssertEqual(hidden, [], "\(message): no hidden staging folder")
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf after it staged its folder, the row reads Cancelled with
    /// no reload, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output folder or a hidden staging folder.
    private func assertCancel(_ item: Case) async throws {
        let root = scratch.appendingPathComponent("cancel-" + item.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(item, in: root)
        let plan = try plan(item, in: root)
        let hold = root.appendingPathComponent("held")
        let reloads = ReloadCalls()
        let begun = try XCTUnwrap(
            begin(plan, in: root, environment: [ViewerExportLeaf.holdFileVariable: hold.path], reloads: reloads))
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf staged its folder and reached the checkpoint")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let row = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(row?.state, .cancelled)
        XCTAssertEqual(reloads.count, 0, "a cancel reloads nothing")
        try assertNothingLeft(plan.output, in: root, "the row's cancel")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(row?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [ViewerExportLeaf.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains(ViewerExportLeaf.cancelledMessage), run.stdout)
        try assertNothingLeft(plan.output, in: root, "the command's cancel")
    }
}
