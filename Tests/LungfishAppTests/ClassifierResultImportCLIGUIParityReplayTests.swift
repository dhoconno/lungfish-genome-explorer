// ClassifierResultImportCLIGUIParityReplayTests.swift - The Import Center's classifier result imports against import <kind>
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04 (A63-M2a), plan decisions C4, C12 and R-A1 on lane Q30's harness. The Import Center imports
// a Kraken2, EsViritu or TaxTriage result into the project's Imports folder. Each case runs on three sides that start
// as copies of one project.
//
// - Side A is the helper's call in process, `MetagenomicsImportService.import<Kind>`, which the app ran in
//   `--metagenomics-import-helper` mode before the route moved, with the command the leaf records.
// - Side C is the app's route, `ClassifierResultImportCLIRoute.arguments` on `CLIBundleBuildRunner`, which launches
//   the built `lungfish-cli import <kind>`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C declares nothing. Side A passes the command the leaf records, which is the helper's canonical command
// (`ClassifierResultImportRecordTests` pins it). The fixtures carry the dotted sample id `S1.2024` (BIO 5).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier. No
// external tool runs.

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
final class ClassifierResultImportCLIGUIParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "classifier-import-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // The sidecars of the result folders stamp the second they were saved (`savedAt` of `esviritu-result.json`,
        // `created` of `analysis-metadata.json`), which differs between any two runs. The contract masks those keys by
        // name (`Masks.resultSidecarClocks`, ruling 1 of the review of lane 12.06 M1), and no pattern runs over the
        // text of a payload, so the standard policy is the whole compare.
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: .standard, replayTimeout: .seconds(300))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheKraken2RowImportsWhatTheHelperImported() async throws {
        try await assertParity(.kraken2)
    }

    func testTheEsVirituRowImportsWhatTheHelperImported() async throws {
        try await assertParity(.esviritu)
    }

    func testTheTaxTriageRowImportsWhatTheHelperImported() async throws {
        try await assertParity(.taxtriage)
    }

    /// The row's command is the argv the runner runs, `--format json` included, from one builder (finding 1 of the
    /// review of lane 12.04). The input has a space in its path and the name has spaces around it, and the row,
    /// split into words as a shell does, equals `ClassifierResultImportCLIRoute.arguments`.
    func testTheRowCommandIsTheArgvTheRunnerRuns() throws {
        let imports = scratch.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        for (kind, name) in [(MetagenomicsImportKind.kraken2, "S1.2024.kreport"), (.esviritu, "S1.2024"), (.taxtriage, "run.2024")] {
            let input = scratch.appendingPathComponent("Incoming folder/\(name)")
            let reporter = RecordingOperationReporter()
            AppDelegate.beginClassifierResultImportOperation(
                kind: kind, operationTitle: "Import", inputURL: input, outputDirectory: imports, preferredName: " S1 sample ",
                naoMgsOptions: nil, routeContext: nil, reporter: reporter, launch: { _ in }
            )
            let words = try RecordedCLICommand.arguments(of: reporter.items.first?.cliCommand)
            XCTAssertEqual(
                words,
                ClassifierResultImportCLIRoute.arguments(kind: kind, inputURL: input, outputDirectory: imports, preferredName: " S1 sample "),
                "\(kind): the row shows the argv the runner runs"
            )
            XCTAssertEqual(Array(words.suffix(2)), ["--format", "json"], "\(kind): the row shows the option the runner ran")
            XCTAssertTrue(words.contains(input.path) && words.contains("S1 sample"), "\(kind): \(words)")
        }
    }

    /// The row's Cancel through the real transport with every core busy (X14). The command exits 125 inside the grace,
    /// records the run as cancelled in the project and leaves no process, the row ends Cancelled with no alert, and
    /// the folder the import began is gone.
    func testACancelOfTheRowEndsCancelledWithNoAlertAndNothingLeft() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        let (input, imports, project) = try Self.writeFixture(.esviritu, in: root)
        try ClassifierImportAppFixtures.addLargeSparseFile(to: input)
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }

        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let operationID = try XCTUnwrap(AppDelegate.beginClassifierResultImportOperation(
            kind: .esviritu, operationTitle: "EsViritu Import", inputURL: input, outputDirectory: imports,
            preferredName: nil, naoMgsOptions: nil, routeContext: nil, onCancel: { runner.cancel() }, launch: { _ in }
        ).startedID)
        let arguments = ClassifierResultImportCLIRoute.arguments(kind: .esviritu, inputURL: input, outputDirectory: imports, preferredName: nil)
        let run = Task { await ClassifierResultImportCLIRoute.run(runner, arguments: arguments, operationID: operationID, operationTitle: "EsViritu Import") }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            !((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).isEmpty
        }
        XCTAssertTrue(started, "the command never made its result folder")
        let cancelledAt = ContinuousClock.now
        OperationCenter.shared.cancel(id: operationID)
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled, "a cancel shows no alert")
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, CLIProcessLauncher.operationGrace, "the command ended inside the grace")
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == operationID }?.state, .cancelled)
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue, "cancelled", "the record reads cancelled")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [], [], "the folder the import began is gone")
        let burnerIDs = Set(burners.map(\.processIdentifier))
        let noneLeft = await waitUntil(timeout: .seconds(30)) {
            Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid())).subtracting(burnerIDs).isEmpty
        }
        XCTAssertTrue(noneLeft, "no process of the command is left")
    }

    /// A failed import through the real transport (QA 4, UX 4, finding 3 of the review of lane 12.04). The input is
    /// missing, so the command prints `failed` with its words and exits with the input error. The route returns
    /// those words with the alert, the row fails with the same words, no result folder is left and the project
    /// holds no cancelled record.
    func testAFailedImportFailsTheRowWithTheCommandsWordsAndShowsTheAlert() async throws {
        let root = scratch.appendingPathComponent("failed", isDirectory: true)
        let (_, imports, project) = try Self.writeFixture(.kraken2, in: root)
        let missing = project.appendingPathComponent("Incoming/missing.kreport")
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let operationID = try XCTUnwrap(AppDelegate.beginClassifierResultImportOperation(
            kind: .kraken2, operationTitle: "Kraken2 Import", inputURL: missing, outputDirectory: imports,
            preferredName: nil, naoMgsOptions: nil, routeContext: nil, onCancel: { runner.cancel() }, launch: { _ in }
        ).startedID)
        let outcome = await ClassifierResultImportCLIRoute.run(
            runner,
            arguments: ClassifierResultImportCLIRoute.arguments(kind: .kraken2, inputURL: missing, outputDirectory: imports, preferredName: nil),
            operationID: operationID,
            operationTitle: "Kraken2 Import"
        )
        let words = "Kreport file not found: \(missing.path)"
        XCTAssertEqual(outcome, .failed(words, alert: true), "a failure shows its alert")
        let row = OperationCenter.shared.items.first { $0.id == operationID }
        XCTAssertEqual(row?.state, .failed)
        XCTAssertEqual(row?.detail, words, "the row fails with the command's words")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [], [], "no folder is left")
        XCTAssertNotEqual(ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue, "cancelled", "a failure is no cancel")
    }

    // MARK: - The sides

    private func assertParity(_ kind: MetagenomicsImportKind, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await harness.assertParity(
            kind.rawValue,
            declared: [],
            in: scratch.appendingPathComponent(kind.rawValue, isDirectory: true),
            fixture: { root in _ = try Self.writeFixture(kind, in: root) },
            sideA: { root in Self.sideA(kind, root) },
            sideC: { root in await self.sideC(kind, root) }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)", file: file, line: line)
        }
        XCTAssertEqual(result.runs.a.outcome.detail, result.runs.c.outcome.detail, "the row's complete words", file: file, line: line)
        XCTAssertTrue(result.runs.c.outcome.detail.hasPrefix("Imported "), result.runs.c.outcome.detail, file: file, line: line)
    }

    nonisolated private static func writeFixture(_ kind: MetagenomicsImportKind, in root: URL) throws -> (input: URL, imports: URL, project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let incoming = project.appendingPathComponent("Incoming", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let input: URL
        switch kind {
        case .kraken2: input = try ClassifierImportAppFixtures.kraken2Report(in: incoming)
        case .esviritu: input = try ClassifierImportAppFixtures.esVirituResult(in: incoming)
        default: input = try ClassifierImportAppFixtures.taxTriageResult(in: incoming)
        }
        return (input, imports, project)
    }

    nonisolated private static func input(_ kind: MetagenomicsImportKind, _ root: URL) -> (input: URL, imports: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let name = kind == .kraken2 ? "S1.2024.kreport" : kind == .esviritu ? "S1.2024" : "run.2024"
        return (project.appendingPathComponent("Incoming/\(name)"), project.appendingPathComponent("Imports", isDirectory: true))
    }

    /// Side A. The service in process, as the helper ran it, with the command the leaf records, and the helper's words.
    nonisolated private static func sideA(_ kind: MetagenomicsImportKind, _ root: URL) -> RouteParitySideOutcome {
        let (input, imports) = input(kind, root)
        let command = ["lungfish-cli", "import", kind.importCommandToken, input.path, "--output-dir", imports.path]
        do {
            switch kind {
            case .kraken2:
                let result = try MetagenomicsImportService.importKraken2(kreportURL: input, outputDirectory: imports, provenanceCommand: command)
                return RouteParitySideOutcome(end: .completed, detail: "Imported Kraken2 result: \(grouped(result.totalReads)) reads, \(result.speciesCount) species")
            case .esviritu:
                let result = try MetagenomicsImportService.importEsViritu(inputURL: input, outputDirectory: imports, provenanceCommand: command)
                return RouteParitySideOutcome(end: .completed, detail: "Imported EsViritu result: \(result.importedFileCount) files, \(result.virusCount) detections")
            default:
                let result = try MetagenomicsImportService.importTaxTriage(inputURL: input, outputDirectory: imports, provenanceCommand: command)
                return RouteParitySideOutcome(end: .completed, detail: "Imported TaxTriage result: \(result.importedFileCount) files")
            }
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The row the Import Center begins and the argv it runs on the runner that launches the built CLI.
    private func sideC(_ kind: MetagenomicsImportKind, _ root: URL) async -> RouteParitySideOutcome {
        let (input, imports) = Self.input(kind, root)
        let reporter = RecordingOperationReporter()
        guard let operationID = AppDelegate.beginClassifierResultImportOperation(
            kind: kind, operationTitle: "Import", inputURL: input, outputDirectory: imports, preferredName: nil,
            naoMgsOptions: nil, routeContext: nil, reporter: reporter, launch: { _ in }
        ).startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let command = reporter.items.first?.cliCommand
        do {
            let result = try await CLIBundleBuildRunner(cliURLOverride: harness.cliBinary).run(
                arguments: ClassifierResultImportCLIRoute.arguments(kind: kind, inputURL: input, outputDirectory: imports, preferredName: nil),
                operationID: operationID
            )
            return RouteParitySideOutcome(end: .completed, detail: result.message ?? "", recordedCommand: command)
        } catch is CancellationError {
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled", recordedCommand: command)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    nonisolated private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
