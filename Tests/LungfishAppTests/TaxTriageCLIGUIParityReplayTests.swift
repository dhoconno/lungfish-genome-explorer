// TaxTriageCLIGUIParityReplayTests.swift - Today's TaxTriage GUI route against its recorded command, on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1a, the freeze that lands before any behaviour commit of A1 or A2 (QA 1). It
// carries Moved out row 249 of the 2.8 plan, 2.7 T2 and T9, 2.8 T16 with the TF-G stand-in, and
// the QA ruling on O5, under which this class runs only the stand-in. Each case runs two sides,
// one after another, on one stand-in engine.
//
// - Side A is today's GUI route. `AppDelegate.runTaxTriage(config:...)` runs the config the
//   TaxTriage wizard builds for the case's bundles on `OperationCenter.shared`, with
//   `AppDelegate.TaxTriageLaunchSeam.makeRunner` bound to the engine and `LUNGFISH_CLI_PATH`
//   naming the built CLI for its `build-db taxtriage` step (2.7 T9).
// - Side B is the command side A's row recorded, rebased onto a fresh root and run in this
//   process with `TaxTriageCommand.RunSubcommand.makePipeline` bound to the same engine, as
//   docs/contracts/CLI-EQUIVALENCE.md replays a command. A request of several samples records
//   no command (cli-parity-gap taxtriage-multi-sample), so side B runs today's one command for
//   it, a folder `--input` that pools the samples in one Nextflow run (2.8 T2, QA inventory 2.2).
//
// Each case checks the fixed facts on each side (TaxTriageCLIGUIParityReplayTests+FixedFacts.swift)
// and compares the two side roots, every provenance record by its facts and the terminal state
// (TaxTriageCLIGUIParityReplayTests+Compare.swift). TaxTriageParityKnownDifferences declares every
// difference of A against B with its count, and the case fails on any other. Lane Q1b adds sides
// C and C' to the same cases.
//
// The stand-in starts processes and side A runs on `OperationCenter.shared`, so the class name ends
// in ReplayTests, which sends it to the serial replay tier. `TaxTriageParityEngine` takes the
// engine's root, profile and database as parameters, so a live class can run the same sides on a
// managed root (ruling O5). `LUNGFISH_PARITY_DUMP=<folder>` keeps a copy of each case's roots and
// its findings in that folder.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageCLIGUIParityReplayTests: XCTestCase {
    var scratch: URL!
    var cliBinary: URL!
    private var savedCLIPath: String?

    enum ParityError: Error {
        case missingCLI
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-parity")
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it side A's build-db step builds no taxtriage.sqlite."
            )
            throw ParityError.missingCLI
        }
        cliBinary = cli
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }

    override func tearDown() async throws {
        if cliBinary != nil {
            if let savedCLIPath {
                setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testX1OneSampleOfTheVirtualSubsetBundle() async throws {
        try await assertParity(.x1)
    }

    func testX2TheSARSCoV2PairAsOneSample() async throws {
        try await assertParity(.x2)
    }

    func testX3TwoSamplesInOneLaunchRequest() async throws {
        try await assertParity(.x3)
    }

    // MARK: - One case

    func assertParity(_ parityCase: TaxTriageParityCase) async throws {
        if parityCase.materializesVirtualBundle {
            _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        }
        let caseRoot = scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: caseRoot)
        func root(_ side: TaxTriageParitySide) -> URL {
            caseRoot.appendingPathComponent(side.folderName, isDirectory: true)
        }
        // One project, copied, so every side starts from the same bytes.
        let projectA = try parityCase.makeProject(in: root(.a))
        try FileManager.default.createDirectory(at: root(.b), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: projectA, to: root(.b).appendingPathComponent(projectA.lastPathComponent, isDirectory: true))
        let engine = try makeStandInEngine(in: caseRoot)

        let runA = try await runGUISide(parityCase, root: root(.a), engine: engine)
        let runB = await runReplay(of: runA, parityCase, root: root(.b), engine: engine)

        var found: [TaxTriageParityScope: [TaxTriageParityDifference]] = [:]
        for run in [runA, runB] {
            found[.side(run.side)] = try fixedFactViolations(parityCase, run: run, engine: engine)
        }
        found[.pair(.a, .b)] = try TaxTriageParityComparison.differences(
            reference: runA,
            candidate: runB,
            bundlePaths: parityCase.bundlePaths
        )
        try dumpIfRequested(parityCase, caseRoot: caseRoot, runs: [runA, runB], found: found)

        for scope in Self.scopes {
            let failures = TaxTriageParityKnownDifferences.failures(found: found[scope] ?? [], parityCase: parityCase, scope: scope)
            if !failures.isEmpty {
                XCTFail("\(parityCase.rawValue), \(scope):\n" + failures.joined(separator: "\n"))
            }
        }
    }

    /// Every side's fixed facts, then A against B, frozen at the base, which may only shrink
    /// (2.7 T2).
    static let scopes: [TaxTriageParityScope] = [.side(.a), .side(.b), .pair(.a, .b)]

    /// The case's stand-in engine in `caseRoot`, with an empty Kraken2 database folder beside it,
    /// which the pipeline checks and the stand-in never reads. Both sides run on it one after the
    /// other, so the launches it numbers by counting a folder never collide (2.8 row 249). A
    /// teardown block stops any stand-in process the case left (QA checklist 2).
    private func makeStandInEngine(in caseRoot: URL) throws -> TaxTriageParityEngine {
        let database = caseRoot.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let engine = try TaxTriageStandInEngine(root: caseRoot.appendingPathComponent("engine", isDirectory: true))
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return .standIn(engine, databasePath: database)
    }

    // MARK: - Dump

    /// `LUNGFISH_PARITY_DUMP`, the folder that keeps each case's roots and findings.
    static var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Copies the case root, which holds both side roots and the engine's launch records, into the
    /// case's dump folder and writes each side's end, row, launches and every difference beside it.
    private func dumpIfRequested(
        _ parityCase: TaxTriageParityCase,
        caseRoot: URL,
        runs: [TaxTriageParitySideRun],
        found: [TaxTriageParityScope: [TaxTriageParityDifference]]
    ) throws {
        guard let folder = Self.dumpFolder?.appendingPathComponent(parityCase.rawValue, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: caseRoot, to: folder)
        var report: [String] = []
        for run in runs {
            report.append("side \(run.side): \(run.terminal), analysis \(run.analysisPath ?? "none")")
            if let command = run.recordedCommand { report.append("recorded command:\n\(command)") }
            report += run.replayedCommands.map { "replayed: \($0.argv.dropFirst().joined(separator: " "))" }
            report += run.launches.map { "launch \($0.folder.lastPathComponent): exit \($0.exitStatus.map(String.init) ?? "none"), \($0.fastqRecords)" }
            if let row = run.row {
                report.append("row: \(row.title) | \(row.firstDetail) | \(row.stateLabel) | \(row.completionDetail) | error \(row.errorMessage ?? "none") | alert \(row.alertText ?? "none")")
                report += row.logLines.map { "  \($0)" }
            }
        }
        for (scope, differences) in found.sorted(by: { $0.key.description < $1.key.description }) {
            report.append("\(scope): \(differences.count)")
            report += differences.map { "  \($0)" }
        }
        try (report.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
