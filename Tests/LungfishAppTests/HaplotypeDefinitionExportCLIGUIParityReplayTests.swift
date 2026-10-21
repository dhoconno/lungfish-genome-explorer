// HaplotypeDefinitionExportCLIGUIParityReplayTests.swift - The haplotype manager's definition export in the app
// against its leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B7, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three
// sides that start as copies of one project with two definitions, saved once outside the case folder and copied in.
//
// - Side A is `exportSelected` as the manager window ran it before its row, the service in process given the record
//   the window lists, frozen in this file since the lane replaces it.
// - Side C is the view model's run helper, `runDefinitionExport`, given the same record. It begins the row and runs
//   the built `lungfish-cli haplotypes export` with the project, assay and scope on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares the definition byte for byte and every fact of the record but its times and its command,
// with each side's root read as one token. The argv, durable replay argv and reproducible command are prediction
// rows of the lane report (BIO 7), pinned by `assertPredictedRecordChanges`. Nothing is declared, so the in-app path
// goes in the lane with no key (R-A1, C4).
//
// Each case root sits five folders below the temporary folder (SCR/lanes/12.31/12.31-cancel.md). The cancel runs
// through the real transport. The leaf holds before it writes on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel
// stops it, and neither the file nor its record is left (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class DefinitionExportParityFailureCalls {
    var messages: [String] = []
}

@MainActor
final class HaplotypeDefinitionExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case firstOfTwo
        case secondOfTwo

        var definitionID: String { self == .firstOfTwo ? "custom.export" : "custom.other" }
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let projectRelativePath = "Project/macaques.lungfish"

    private var scratch: URL!
    private var fixtureProject: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "haplotype-definition-export-parity")
        fixtureProject = scratch.appendingPathComponent("fixture/macaques.lungfish", isDirectory: true)
        let store = HaplotypeDefinitionStore(projectRoot: fixtureProject)
        try store.seed(Self.definition(id: "custom.export", assayID: "MHC-exon2-miSeq", name: "Export Me"))
        try store.seed(Self.definition(id: "custom.other", assayID: "MHC-exon4-ONT", name: "Other"))
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheFirstOfTwoDefinitionsMatches() async throws {
        try await assertParity(.firstOfTwo)
    }

    func testTheSecondOfTwoDefinitionsMatches() async throws {
        let runs = try await assertParity(.secondOfTwo)
        let exported = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self, from: Data(contentsOf: Self.outputURL(in: runs.c.root))
        )
        XCTAssertEqual(exported.assayID, "MHC-exon4-ONT")
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf before it writes, the row reads Cancelled with no
    /// message, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the file or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = Self.caseFolder(in: scratch).appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = Self.sidecarURL(for: output)
        let hold = root.appendingPathComponent("held")

        let failures = DefinitionExportParityFailureCalls()
        let begun = try XCTUnwrap(HaplotypeDefinitionManagerViewModel.runDefinitionExport(
            record: try Self.record(.firstOfTwo, in: root),
            projectURL: Self.projectURL(in: root),
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its hold")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The fixture

extension HaplotypeDefinitionExportCLIGUIParityReplayTests {
    /// The folder the case roots sit in, five folders below the temporary folder.
    static func caseFolder(in scratch: URL) -> URL {
        scratch.appendingPathComponent("cases/of/the/haplotype", isDirectory: true)
    }

    /// The project as the manager window holds it, standardized.
    static func projectURL(in root: URL) -> URL {
        root.appendingPathComponent(projectRelativePath, isDirectory: true).standardizedFileURL
    }

    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("exported.lungfishhaplotypedef.json")
    }

    static func sidecarURL(for output: URL) -> URL {
        output.appendingPathExtension("provenance.json")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecarURL(for: outputURL(in: root))))
    }

    /// The record the manager window lists for the case's definition, as its `reload` reads them.
    static func record(_ parityCase: Case, in root: URL) throws -> HaplotypeDefinitionRecord {
        let records = HaplotypeDefinitionCommandService(projectRoot: projectURL(in: root), toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind)
            .listDefinitions(includeShadowed: true, includeReferenceBundles: true)
        return try XCTUnwrap(records.first { $0.definitionSet.id == parityCase.definitionID })
    }

    static func definition(id: String, assayID: String, name: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: assayID,
            displayName: name,
            speciesName: "Mauritian cynomolgus macaques",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"]),
                    ]
                ),
            ]
        )
    }

    /// The project saved once in setUp, copied into the root.
    func makeFixture(_ root: URL) throws {
        let project = Self.projectURL(in: root)
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureProject, to: project)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - The sides

extension HaplotypeDefinitionExportCLIGUIParityReplayTests {
    /// Side A. `exportSelected` as the manager window ran it before its row, given the record it lists.
    private func sideA(_ root: URL, case parityCase: Case) -> RouteParitySideOutcome {
        do {
            let record = try Self.record(parityCase, in: root)
            let url = Self.outputURL(in: root)
            try HaplotypeDefinitionCommandService(projectRoot: Self.projectURL(in: root), toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind).exportDefinition(
                definitionID: record.definitionSet.id,
                assayID: record.definitionSet.assayID,
                scope: record.scope,
                to: url,
                argv: [CLICommandIdentity.executableName, "haplotypes", "export", record.definitionSet.id, "--output", url.path]
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported the definition")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The view model's run helper, which runs the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, case parityCase: Case) async throws -> RouteParitySideOutcome {
        let failures = DefinitionExportParityFailureCalls()
        guard let begun = HaplotypeDefinitionManagerViewModel.runDefinitionExport(
            record: try Self.record(parityCase, in: root),
            projectURL: Self.projectURL(in: root),
            outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }
}

// MARK: - The comparison

extension HaplotypeDefinitionExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: Self.caseFolder(in: scratch).appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try self.makeFixture(root) },
            sideA: { root in self.sideA(root, case: parityCase) },
            sideC: { root in try await self.sideC(root, case: parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs)
        try assertPredictedRecordChanges(runs, case: parityCase)
        return runs
    }

    /// A against C with each path read relative to its side root. No file but the record differs, and the record
    /// is equal on everything but its times and its command.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = Self.sidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payload = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payload, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the definition byte for byte")
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(a.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(a.toolName, c.toolName, "the tool")
        XCTAssertEqual(a.workflowName, "Haplotype definition export")
        XCTAssertEqual(a.workflowName, c.workflowName, "the workflow")
        let filesA = Self.files(of: a, under: runs.a.root)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(filesA.values.contains(digest), "the output's digest is the definition's, \(filesA)")
        XCTAssertTrue(filesA.keys.contains { $0.contains("/\(Self.projectRelativePath)/") }, "the definition file read, \(filesA)")
        XCTAssertEqual(filesA, Self.files(of: c, under: runs.c.root), "every file with its role and digest")
        XCTAssertEqual(Self.texts(a.options.explicit, under: runs.a.root), Self.texts(c.options.explicit, under: runs.c.root))
        XCTAssertEqual(Self.texts(a.options.defaults, under: runs.a.root), Self.texts(c.options.defaults, under: runs.c.root))
        XCTAssertEqual(
            Self.texts(a.options.resolvedDefaults, under: runs.a.root),
            Self.texts(c.options.resolvedDefaults, under: runs.c.root),
            "the project root and scope"
        )
    }

    /// The prediction rows of the lane report (BIO 7). The record's command gains the project, the assay and the
    /// scope the export used, and it is the row's command (ARCH 2). Tool and workflow do not move.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, case parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let argvA = [
            CLICommandIdentity.executableName, "haplotypes", "export", parityCase.definitionID,
            "--output", Self.outputURL(in: runs.a.root).path,
        ]
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        let record = try Self.record(parityCase, in: runs.c.root)
        XCTAssertEqual(rowArguments, HaplotypeDefinitionExport.arguments(
            definitionID: parityCase.definitionID,
            outputPath: Self.outputURL(in: runs.c.root).path,
            projectPath: Self.projectURL(in: runs.c.root).path,
            assayID: record.definitionSet.assayID,
            scope: "project"
        ))
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
    }

    /// Each file of the record below `root`, keyed by its role and path, with its digest.
    private static func files(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        var files: [String: String] = [:]
        for file in envelope.files {
            files["\(file.role) \(relativePath(file.path, under: root))"] = file.checksumSHA256 ?? "no digest"
        }
        return files
    }

    /// Each option as text with a path below `root` read relative to it.
    private static func texts(_ options: [String: ParameterValue], under root: URL) -> [String: String] {
        options.mapValues { value in
            if case .file(let url) = value {
                return relativePath(url.path, under: root)
            }
            return relativePath(value.stringValue ?? "\(value)", under: root)
        }
    }

    private static func relativePath(_ path: String, under root: URL) -> String {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        let rootPath = rootPaths.first { path.hasPrefix($0 + "/") }
        return rootPath.map { "<ROOT>" + String(path.dropFirst($0.count)) } ?? path
    }
}
