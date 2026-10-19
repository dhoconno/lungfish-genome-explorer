// CzIdImportCLIGUIParityReplayTests.swift - The CZ-ID import in process against import cz-id
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3, K4 p17), decisions C4 of Phase 2.10 and C12 of Phase 2.11, on lane Q30's
// harness. The Import Center imports a CZ-ID taxon report into the project's Classifications folder. Each case
// runs on three sides that start as copies of one project.
//
// - Side A is the import the app ran in process before the route moved, `CzIdProjectImportWorkflow.importFromURL`
//   with the report's sample name. It records the leaf's own command, so A against C declares nothing.
// - Side C is the app's route, `CzIdImportCLICommand.arguments` on `CLIBundleBuildRunner`, which launches the
//   built `lungfish-cli import cz-id`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier. It
// needs no tool.

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
final class CzIdImportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case taxonReport
    }

    nonisolated private static let sampleName = "Sample-CZ-001"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "cz-id-import-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // A classification result (`classification-result.json`) stamps the seconds the conversion took (`runtime`)
        // and the time it saved the result (`savedAt`), which two runs of one command never share. The contract masks
        // those keys by the document's key set (`Masks.resultSidecarClocks`, ruling 1 of the review of lane 12.06 M1),
        // so the standard policy is the whole compare.
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: .standard, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheCzIdRowImportsWhatTheInProcessImportImported() async throws {
        let result = try await harness.assertParity(
            Case.taxonReport,
            declared: [],
            in: scratch.appendingPathComponent(Case.taxonReport.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root, speciesRows: 0) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root) }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
            let record = try XCTUnwrap(
                ProvenanceEnvelopeReader.loadCanonical(from: Self.paths(run.root).bundle),
                "side \(run.side) records the import in the bundle"
            )
            let step = try XCTUnwrap(record.steps.first)
            XCTAssertEqual(step.toolName, "lungfish import cz-id", "side \(run.side)")
            XCTAssertEqual(Array(step.argv.prefix(3)), ["lungfish-cli", "import", "cz-id"], "side \(run.side): \(step.argv)")
        }
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row's complete words")
    }

    /// Side C and its replay are cancelled through the real transport while the command reads a large report, with
    /// every core busy. Each exits 125 inside the grace, its record in the project reads cancelled and no process of
    /// its tree is left (`assertCancelled`), and the cancelled import publishes nothing. Side A is not run, since the
    /// in-process import had no cancel that reached the conversion.
    func testACancelWhileReadingEndsCancelledWithEveryCoreBusyAndPublishesNothing() async throws {
        let cancel = RouteParityCancel(
            when: { root in FileManager.default.fileExists(atPath: Self.classifications(root).path) },
            record: { root in ProvenanceRecorder.loadEnvelope(from: Self.paths(root).project)?.status.rawValue }
        )
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }
        let cli = harness.cliBinary
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("cancel", isDirectory: true),
            cancel: cancel,
            fixture: { root in try Self.writeFixture(root, speciesRows: 200_000) },
            sideA: { _ in RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process import had no cancel that reached the conversion") },
            sideC: { root in
                let (report, _, project) = Self.paths(root)
                let run = await RouteParityHarness.runCLI(
                    cli,
                    arguments: CzIdImportCLICommand.arguments(sourceURL: report, projectURL: project, sampleName: Self.sampleName),
                    timeout: .seconds(120),
                    environment: [:],
                    cancelWhen: { cancel.isReached(root) }
                )
                return RouteParitySideOutcome(
                    end: run.end,
                    detail: run.detail,
                    recordedCommand: Self.rowCommand(report: report, project: project),
                    cancel: run.cancel
                )
            }
        )
        for side in [runs.c, runs.cPrime] {
            XCTAssertEqual(side.outcome.end, .cancelled, "\(side.side): \(side.outcome.detail)")
            await RouteParityHarness.assertCancelled(side, cancel)
            XCTAssertEqual(
                (try? FileManager.default.contentsOfDirectory(atPath: Self.classifications(side.root).path)) ?? [], [],
                "side \(side.side): a cancelled import publishes nothing"
            )
        }
    }

    // MARK: - The sides

    nonisolated private static func paths(_ root: URL) -> (report: URL, bundle: URL, project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        return (
            project.appendingPathComponent("Incoming/taxon_report.tsv"),
            project.appendingPathComponent("Classifications/\(sampleName).lungfishtax", isDirectory: true),
            project
        )
    }

    nonisolated private static func classifications(_ root: URL) -> URL {
        paths(root).project.appendingPathComponent("Classifications", isDirectory: true)
    }

    /// The command the row records, as `AppDelegate.beginCzIdImportOperation` builds it.
    nonisolated private static func rowCommand(report: URL, project: URL) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "import",
            args: ["cz-id", report.path, "--project", project.standardizedFileURL.path, "--sample-name", sampleName]
        )
    }

    /// Side A. The import in process, as the app ran it before the route moved.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        let (report, _, project) = Self.paths(root)
        do {
            let imported = try await CzIdProjectImportWorkflow.importFromURL(report, projectURL: project, sampleName: Self.sampleName)
            return RouteParitySideOutcome(end: .completed, detail: "Imported \(imported.sampleName)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The row the Tools menu begins and the argv it runs on the runner that launches the built CLI.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let (report, _, project) = Self.paths(root)
        let reporter = RecordingOperationReporter()
        guard let operationID = AppDelegate.beginCzIdImportOperation(
            sourceURL: report,
            projectURL: project,
            sampleName: Self.sampleName,
            reportFileName: report.lastPathComponent,
            routeContext: nil,
            reporter: reporter,
            launch: { _ in }
        ).startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let command = reporter.items.first?.cliCommand
        XCTAssertEqual(command, Self.rowCommand(report: report, project: project))
        do {
            _ = try await CLIBundleBuildRunner(cliURLOverride: harness.cliBinary).run(
                arguments: CzIdImportCLICommand.arguments(sourceURL: report, projectURL: project, sampleName: Self.sampleName),
                operationID: operationID
            )
            return RouteParitySideOutcome(end: .completed, detail: "Imported \(Self.sampleName)", recordedCommand: command)
        } catch is CancellationError {
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled", recordedCommand: command)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    // MARK: - Fixture

    /// A project with the taxon report in its `Incoming` folder, so the path of the input masks to the project in
    /// every record. The report has a root, a superkingdom and a species row, and `speciesRows` more species rows
    /// for a run that a cancel must meet while it reads.
    nonisolated private static func writeFixture(_ root: URL, speciesRows: Int) throws {
        let report = paths(root).report
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefix = "\(sampleName)\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01"
        var text = "sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank"
            + "\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm\n"
        text.reserveCapacity(speciesRows * 110 + 1_000)
        text += "\(prefix)\t1\troot\troot\t1200\t1000000\t1200\t1000000\n"
        text += "\(prefix)\t10239\tViruses\tsuperkingdom\t88\t73333\t12\t10000\n"
        text += "\(prefix)\t2697049\tSevere acute respiratory syndrome coronavirus 2\tspecies\t42\t35000\t5\t4166.7\n"
        for row in 0..<speciesRows {
            text += "\(prefix)\t\(100_000 + row)\tTaxon \(row)\tspecies\t\(row % 97 + 1)\t\(row % 89 + 1)\t1\t1\n"
        }
        try text.write(to: report, atomically: true, encoding: .utf8)
    }
}
