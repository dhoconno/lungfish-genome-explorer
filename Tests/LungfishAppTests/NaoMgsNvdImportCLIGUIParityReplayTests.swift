// NaoMgsNvdImportCLIGUIParityReplayTests.swift - The Import Center's NAO-MGS and NVD imports against import <kind>
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05 (A63-M2b), plan decisions C4, C12 and R-A1 on lane Q30's harness, on the pattern of lane 12.04.
// The Import Center imports a NAO-MGS result or an NVD run. Each case runs on three sides that start as copies of one
// project.
//
// - Side A is the service in process, `MetagenomicsImportService.importNaoMgs` or `importNvd`, which the app ran in
//   `--metagenomics-import-helper` mode before the route moved, with the command the leaf records.
// - Side C is the app's route, `ClassifierResultImportCLIRoute.arguments` on `CLIBundleBuildRunner`, which launches
//   the built `lungfish-cli import <kind>`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// A against C declares nothing. Side A passes the command the leaf records, which is the route's argv without
// `--format json`. The fixtures carry the dotted sample ids `S1.2024` and `S2.2024` (BIO 5). NAO-MGS runs with
// `--no-fetch-references` under a managed storage that holds a fixture taxonomy, so no network is used. No external
// tool runs, since the fixtures hold no BAM.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class NaoMgsNvdImportCLIGUIParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var harness: RouteParityHarness!
    private var storageBefore: String?

    override func setUp() async throws {
        scratch = try TestTempDirectory.make(prefix: "naomgs-nvd-parity")
        storageBefore = NaoMgsNvdAppFixtures.useStorage(try await NaoMgsNvdAppFixtures.installFixtureTaxonomy(in: scratch))
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // The `created` of an analysis folder's `analysis-metadata.json` stamps the second the folder was made. The
        // contract masks it by name (`Masks.resultSidecarClocks`, ruling 1 of the review of lane 12.06 M1), so the
        // standard policy is the whole compare.
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, masks: .standard, replayTimeout: .seconds(300))
    }

    override func tearDownWithError() throws {
        NaoMgsNvdAppFixtures.restoreStorage(storageBefore)
        TestTempDirectory.cleanup(scratch)
    }

    func testTheNaoMgsRowImportsWhatTheLeafImports() async throws {
        try await assertParity(.naomgs)
    }

    func testTheNvdRowImportsWhatTheLeafImports() async throws {
        try await assertParity(.nvd)
    }

    /// The row's command is the argv the runner runs, `--format json` included, from one builder (finding 1 of the
    /// review of lane 12.04). The input has a space in its path and the name has spaces around it.
    func testTheRowCommandIsTheArgvTheRunnerRuns() throws {
        let imports = scratch.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let naoMgsInput = scratch.appendingPathComponent("Incoming folder/S1.2024", isDirectory: true)
        let naoMgsReporter = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs, operationTitle: "NAO-MGS Import", inputURL: naoMgsInput, outputDirectory: imports,
            preferredName: " S1 sample ", naoMgsOptions: .init(fetchReferences: false), routeContext: nil,
            reporter: naoMgsReporter, launch: { _ in }
        )
        let naoMgsRow = try XCTUnwrap(naoMgsReporter.items.first?.cliCommand)
        let naoMgs = try RecordedCLICommand.parse(naoMgsRow, as: ImportCommand.NaoMgsSubcommand.self)
        XCTAssertEqual(naoMgs.inputPath, naoMgsInput.path)
        XCTAssertEqual(naoMgs.outputDir, imports.path)
        XCTAssertEqual(naoMgs.sampleName, "S1 sample")
        XCTAssertFalse(naoMgs.fetchReferences)
        XCTAssertEqual(naoMgs.globalOptions.outputFormat, .json, "the row shows the option the runner ran")
        XCTAssertEqual(
            naoMgsRow,
            OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(ClassifierResultImportCLIRoute.arguments(
                    kind: .naomgs, inputURL: naoMgsInput, outputDirectory: imports, preferredName: " S1 sample ", fetchReferences: false
                ).dropFirst())
            )
        )

        let nvdInput = scratch.appendingPathComponent("Incoming folder/nvd.2024", isDirectory: true)
        let nvdReporter = RecordingOperationReporter()
        AppDelegate.beginNvdImportOperation(
            sourceURL: nvdInput, importsDirectory: imports, routeContext: nil, reporter: nvdReporter, launch: { _ in }
        )
        let nvdRow = try XCTUnwrap(nvdReporter.items.first?.cliCommand)
        let nvd = try RecordedCLICommand.parse(nvdRow, as: ImportCommand.NvdSubcommand.self)
        XCTAssertEqual(nvd.inputPath, nvdInput.path)
        XCTAssertEqual(nvd.outputDir, imports.path)
        XCTAssertEqual(nvd.globalOptions.outputFormat, .json, "the row shows the option the runner ran")
        XCTAssertEqual(
            nvdRow,
            OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(ClassifierResultImportCLIRoute.arguments(
                    kind: .nvd, inputURL: nvdInput, outputDirectory: imports, preferredName: nil
                ).dropFirst())
            )
        )
    }

    /// The row's Cancel through the real transport with every core busy (X14). The command exits 125 inside the grace,
    /// records the run as cancelled in the project and leaves no process, the row ends Cancelled with no alert, and
    /// the folder the import began is gone.
    func testACancelOfTheNaoMgsRowEndsCancelledWithNoAlertAndNothingLeft() async throws {
        try await assertACancelEndsTheRow(.naomgs, title: "NAO-MGS Import")
    }

    func testACancelOfTheNvdRowEndsCancelledWithNoAlertAndNothingLeft() async throws {
        try await assertACancelEndsTheRow(.nvd, title: "NVD Import")
    }

    private func assertACancelEndsTheRow(_ kind: MetagenomicsImportKind, title: String) async throws {
        let root = scratch.appendingPathComponent("cancel-\(kind.rawValue)", isDirectory: true)
        let (input, imports, project) = try Self.writeFixture(kind, in: root)
        try NaoMgsNvdAppFixtures.addLargeSparseFile(to: input)
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }

        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let operationID = try XCTUnwrap(AppDelegate.beginClassifierResultImportOperation(
            kind: kind, operationTitle: title, inputURL: input, outputDirectory: imports, preferredName: nil,
            naoMgsOptions: kind == .naomgs ? .init(fetchReferences: false) : nil, routeContext: nil,
            onCancel: { runner.cancel() }, launch: { _ in }
        ).startedID)
        let arguments = ClassifierResultImportCLIRoute.arguments(
            kind: kind, inputURL: input, outputDirectory: imports, preferredName: nil, fetchReferences: false
        )
        let run = Task { await ClassifierResultImportCLIRoute.run(runner, arguments: arguments, operationID: operationID, operationTitle: title) }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            !((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).isEmpty
        }
        XCTAssertTrue(started, "the command never made its folder")
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

    /// A failed import through the real transport (QA 4, UX 4, finding 4 of the review of lane 12.05). The input is
    /// missing, so the command prints `failed` with its words and exits with the input error. The route returns those
    /// words with the alert, the row fails with the same words, no folder is left and the project holds no cancelled
    /// record.
    func testAFailedNaoMgsImportFailsTheRowWithTheCommandsWordsAndShowsTheAlert() async throws {
        try await assertAFailedImportShowsTheAlert(.naomgs, title: "NAO-MGS Import", words: "Input not found: ")
    }

    func testAFailedNvdImportFailsTheRowWithTheCommandsWordsAndShowsTheAlert() async throws {
        try await assertAFailedImportShowsTheAlert(.nvd, title: "NVD Import", words: "Input directory not found: ")
    }

    private func assertAFailedImportShowsTheAlert(_ kind: MetagenomicsImportKind, title: String, words: String) async throws {
        let root = scratch.appendingPathComponent("failed-\(kind.rawValue)", isDirectory: true)
        let (_, imports, project) = try Self.writeFixture(kind, in: root)
        let missing = project.appendingPathComponent("Incoming/missing")
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let operationID = try XCTUnwrap(AppDelegate.beginClassifierResultImportOperation(
            kind: kind, operationTitle: title, inputURL: missing, outputDirectory: imports, preferredName: nil,
            naoMgsOptions: kind == .naomgs ? .init(fetchReferences: false) : nil, routeContext: nil,
            onCancel: { runner.cancel() }, launch: { _ in }
        ).startedID)
        let outcome = await ClassifierResultImportCLIRoute.run(
            runner,
            arguments: ClassifierResultImportCLIRoute.arguments(
                kind: kind, inputURL: missing, outputDirectory: imports, preferredName: nil, fetchReferences: false
            ),
            operationID: operationID,
            operationTitle: title
        )
        let detail = words + missing.path
        XCTAssertEqual(outcome, .failed(detail, alert: true), "a failure shows its alert")
        let row = OperationCenter.shared.items.first { $0.id == operationID }
        XCTAssertEqual(row?.state, .failed)
        XCTAssertEqual(row?.detail, detail, "the row fails with the command's words")
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
            sideA: { root in await Self.sideA(kind, root) },
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
        let input = kind == .naomgs
            ? try NaoMgsNvdAppFixtures.naoMgsResult(in: incoming)
            : try NaoMgsNvdAppFixtures.nvdRun(in: incoming)
        return (input, imports, project)
    }

    nonisolated private static func input(_ kind: MetagenomicsImportKind, _ root: URL) -> (input: URL, imports: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let name = kind == .naomgs ? "S1.2024" : "nvd.2024"
        return (project.appendingPathComponent("Incoming/\(name)"), project.appendingPathComponent("Imports", isDirectory: true))
    }

    /// Side A. The service in process, as the helper ran it, with the command the leaf records, and the helper's words.
    nonisolated private static func sideA(_ kind: MetagenomicsImportKind, _ root: URL) async -> RouteParitySideOutcome {
        let (input, imports) = input(kind, root)
        var command = ["lungfish-cli", "import", kind.importCommandToken, input.path, "--output-dir", imports.path]
        do {
            if kind == .naomgs {
                command.append("--no-fetch-references")
                let result = try await MetagenomicsImportService.importNaoMgs(
                    inputURL: input, outputDirectory: imports, fetchReferences: false, provenanceCommand: command
                )
                return RouteParitySideOutcome(
                    end: .completed,
                    detail: "Imported NAO-MGS result: \(grouped(result.totalHitReads)) reads, \(result.taxonCount) taxa"
                )
            }
            let result = try await MetagenomicsImportService.importNvd(
                inputURL: input, outputDirectory: imports, samtoolsPath: MetagenomicsImportService.managedSamtoolsPath(),
                provenanceCommand: command
            )
            return RouteParitySideOutcome(
                end: .completed,
                detail: "Imported NVD result: \(grouped(result.hitCount)) hits, \(result.sampleCount) samples"
            )
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
            naoMgsOptions: kind == .naomgs ? .init(fetchReferences: false) : nil, routeContext: nil,
            reporter: reporter, launch: { _ in }
        ).startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let command = reporter.items.first?.cliCommand
        do {
            let result = try await CLIBundleBuildRunner(cliURLOverride: harness.cliBinary).run(
                arguments: ClassifierResultImportCLIRoute.arguments(
                    kind: kind, inputURL: input, outputDirectory: imports, preferredName: nil, fetchReferences: false
                ),
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
