// TaxTriageParityHarness.swift - The sides, facts and comparison of a TaxTriage parity case, on any engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1a, fix 4 of the QA review of M1 and ruling O5. The stand-in class
// TaxTriageCLIGUIParityReplayTests and a live class (lane Q1b's TaxTriageParityLiveConformanceTests)
// run the same cases. A live class cannot inherit the stand-in class, because XCTest runs inherited
// test methods in a subclass, which would put the stand-in cases in the conformance tier. So the
// side runs (TaxTriageCLIGUIParityReplayTests+Sides.swift), the fixed facts (+FixedFacts.swift),
// the comparison, the declared differences and the dump hang off this type, which either class
// builds with itself and the built CLI and calls with its own engine:
//
//     try await TaxTriageParityHarness(testCase: self, cliBinary: cli)
//         .assertParity(.x2, engine: engine, caseRoot: caseRoot)
//
// `LUNGFISH_PARITY_DUMP=<folder>` keeps a copy of each case's roots and its findings in that folder.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// Runs a TaxTriage parity case on an engine, for the stand-in class and a live class alike.
@MainActor
struct TaxTriageParityHarness {
    /// The test case whose app delegate state and teardown blocks the side runs use.
    let testCase: XCTestCase
    /// The built `lungfish-cli`, which sides C and C' run.
    let cliBinary: URL

    /// Runs sides C and C' of `parityCase` on `engine` in `caseRoot`, checks every side's fixed facts
    /// and C against C' both ways, and fails the test on every difference the declared list does not
    /// hold. `caseRoot` takes the side roots, and the engine may live in it too.
    func assertParity(_ parityCase: TaxTriageParityCase, engine: TaxTriageParityEngine, caseRoot: URL) async throws {
        if parityCase.materializesVirtualBundle {
            _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        }
        func root(_ side: TaxTriageParitySide) -> URL {
            caseRoot.appendingPathComponent(side.folderName, isDirectory: true)
        }
        // One project, copied, so every side starts from the same bytes, and a pristine copy that
        // no side touches, for the bundles no side may write into.
        let projectC = try parityCase.makeProject(in: root(.c))
        let pristine = caseRoot.appendingPathComponent("pristine", isDirectory: true)
            .appendingPathComponent(projectC.lastPathComponent, isDirectory: true)
        for copy in [root(.cPrime).appendingPathComponent(projectC.lastPathComponent, isDirectory: true), pristine] {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: projectC, to: copy)
        }

        // Lane Q1b. Side C, the Tools menu route (Phase 2.11 U30 M3, the only route since 2.12 K1),
        // or X8's plain --output, and side C' replaying the argv C's record names, all through the
        // built lungfish-cli (TaxTriageCLIGUIParityReplayTests+RouteC.swift).
        var runC = parityCase.runsGUISide
            ? try await runGUISide(parityCase, side: .c, root: root(.c), engine: engine)
            : await runRoutedSide(parityCase, root: root(.c), engine: engine)
        if parityCase.rebuildsAfterTheCleanup { runC = await rebuildAfterTheCleanup(runC) }
        var runCPrime = await runRecordedArgv(of: runC, parityCase, root: root(.cPrime), engine: engine)
        if parityCase.rebuildsAfterTheCleanup { runCPrime = await rebuildAfterTheCleanup(runCPrime) }
        let runs = [runC, runCPrime]

        var found: [TaxTriageParityScope: [TaxTriageParityDifference]] = [:]
        for run in runs {
            found[.side(run.side)] = try fixedFactViolations(parityCase, run: run, engine: engine, pristineProject: pristine)
        }
        func differences(_ reference: TaxTriageParitySideRun, _ candidate: TaxTriageParitySideRun) throws -> [TaxTriageParityDifference] {
            try TaxTriageParityComparison.differences(reference: reference, candidate: candidate, bundlePaths: parityCase.bundlePaths)
        }
        // The acceptance (2.7 T2). The record comparison lets the candidate add facts, so C and C'
        // are compared both ways.
        found[.pair(.c, .cPrime)] = try differences(runC, runCPrime)
        found[.pair(.cPrime, .c)] = try differences(runCPrime, runC)
        try dumpIfRequested(parityCase, caseRoot: caseRoot, runs: runs, found: found)

        for scope in Self.scopes {
            let failures = TaxTriageParityKnownDifferences.failures(found: found[scope] ?? [], parityCase: parityCase, scope: scope)
            if !failures.isEmpty {
                XCTFail("\(parityCase.rawValue), \(scope):\n" + failures.joined(separator: "\n"))
            }
        }
    }

    /// Every side's fixed facts, and C against C' both ways, the acceptance, which declares
    /// nothing (2.7 T2). Sides A and B and their pairs left with the legacy route (2.12 K1).
    static let scopes: [TaxTriageParityScope] = [.side(.c), .side(.cPrime), .pair(.c, .cPrime), .pair(.cPrime, .c)]

    // MARK: - Dump

    /// `LUNGFISH_PARITY_DUMP`, the folder that keeps each case's roots and findings.
    static var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Copies the case root, which holds the side roots and the engine's launch records, into the
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
            if let rebuild = run.rebuild { report.append("rebuild: \(rebuild)") }
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
