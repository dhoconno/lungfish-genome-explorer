// ManagedToolsCLIGUIParityReplayTests+Completed.swift - The managed tools commands run to their end on sides C and C'
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3b (family L10, panel decisions C10 and C4, QA 4). The cancel cases in
// ManagedToolsCLIGUIParityReplayTests end every side cancelled. These cases run each side to its end
// against a stand-in micromamba that finishes (ManagedToolsStandInConda), and compare the roots the
// sides leave with kind `.managedPlan`.
//
// - Side C is the argv the L10 runner builds, run by the built `lungfish-cli` through the app's
//   transport launcher, with the root's environment. Side C' is the command the row recorded.
// - There is no side A since Phase 2.11 (K3). The in-process route, the reconciler in the Update Tools
//   sheet and the pack service in the Plugin Manager, went with its hidden key. Side C is the reference,
//   and C against C' declares nothing.
//
// The harness's own `run` replays the recorded command with the root of side C rebased, and refuses a
// command that names no path under that root. These commands name none, because the storage root
// travels in the environment as for every route, so the cases run the two sides themselves and hand
// the runs to `harness.evaluate`.
//
// What the cases check besides the roots.
//
// 1. Rows. The CLI route opens one row for the run, and its command names the chosen items. Checked by
//    the row assertions in each case, since a row is not a file of a root.
// 2. Cancel. The cancel cases of ManagedToolsCLIGUIParityReplayTests cover sides C and C'.
// 3. A database that cannot be updated in place ends in a failed row and an alert on the CLI route. The
//    built CLI has no archive stand-in, so ManagedToolLeavesLiveConformanceTests covers it. Whether the
//    app should show guidance in the row instead is A52's open UX item (declared difference 4).

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// The rows the reconciler opens through its sink when a sheet runs it in this process.
final class RecordingDependencySink: DependencyOperationSink {
    struct Row: Sendable, Equatable {
        let title: String
        let detail: String
    }

    private let state = Mutex<[Row]>([])
    var started: [Row] { state.withLock { $0 } }

    func start(title: String, detail: String) -> UUID {
        state.withLock { $0.append(Row(title: title, detail: detail)) }
        return UUID()
    }

    func update(id: UUID, progress: Double, detail: String) {}
    func log(id: UUID, message: String) {}
    func complete(id: UUID, detail: String) {}
    func fail(id: UUID, detail: String, error: String) {}
}

extension ManagedToolsCLIGUIParityReplayTests {
    enum CompletedCase: Hashable, Sendable, CustomStringConvertible {
        case updateTools
        case packReinstall

        var description: String {
            switch self {
            case .updateTools: return "update-tools"
            case .packReinstall: return "pack-reinstall"
            }
        }
    }

    /// The differences the cases declare. None, since side C is the reference.
    static let declared: [RouteParityDeclaredDifference<CompletedCase>] = []

    // MARK: - Running a case

    /// Runs the argv `invocation` on side C and the command the row recorded on side C', each in a root
    /// that started as a copy of the fixture, then compares the two.
    func runCompleted(
        _ parityCase: CompletedCase,
        invocation: CLIManagedToolsRunner.Invocation,
        recordedCommand command: String?,
        fixture: (URL) throws -> Void
    ) async throws -> RouteParityResult {
        XCTAssertEqual(command, invocation.recordedCommand, "the row records the argv the runner runs")
        let fileManager = FileManager.default
        let caseRoot = scratch.appendingPathComponent("completed-\(parityCase)", isDirectory: true)
        try? fileManager.removeItem(at: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try fileManager.createDirectory(at: rootC, withIntermediateDirectories: true)
        try fixture(rootC)
        try fileManager.copyItem(at: rootC, to: rootCPrime)

        let run = await RouteParityHarness.runCLI(
            cli, arguments: invocation.argv, timeout: .seconds(120), environment: Self.environment(for: rootC)
        )
        let runC = RouteParitySideRun(
            side: .c, root: rootC,
            outcome: RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
        )
        XCTAssertEqual(run.end, .completed, "side C: \(run.detail) \(run.stderr)")

        let replayed = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(command))
        XCTAssertEqual(replayed, invocation.argv, "the recorded command is the argv the runner runs")
        let replay = await RouteParityHarness.runCLI(
            cli, arguments: replayed, timeout: .seconds(120), environment: Self.environment(for: rootCPrime)
        )
        let runCPrime = RouteParitySideRun(
            side: .cPrime, root: rootCPrime,
            outcome: RouteParitySideOutcome(end: replay.end, detail: replay.detail),
            replayedArguments: [replayed]
        )
        XCTAssertEqual(replay.end, .completed, "side C': \(replay.detail) \(replay.stderr)")

        let runs = RouteParityRuns(caseRoot: caseRoot, a: runC, c: runC, cPrime: runCPrime)
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        return result
    }

    // MARK: - Update Tools

    func testAnUpdateToolsRunCompletedOnSidesCAndCPrime() async throws {
        let ids = ["pigz", "samtools"]
        let invocation = CLIManagedToolsRunner.updateTools(ids: ids)
        let reporter = RecordingOperationReporter()
        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools", detail: "\(ids.count) item(s)", cliCommand: invocation.recordedCommand, reporter: reporter
        ) { _ in }

        _ = try await runCompleted(
            .updateTools,
            invocation: invocation,
            recordedCommand: reporter.items.first?.cliCommand,
            fixture: { root in
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("home"), withIntermediateDirectories: true
                )
                let others = ManagedToolLock.bundled.tools.map(\.environment).filter { !ids.contains($0) }
                try ManagedToolsStandInConda.make(
                    storageRoot: Self.storageRoot(of: root), current: others, outdated: ["pigz"], templates: ids
                )
            }
        )

        // Rows, check 1 of the list above.
        XCTAssertEqual(reporter.items.count, 1, "the CLI route opens one row for the run")
        XCTAssertNotNil(reporter.items.first?.cliCommand, "and it records the command")
    }

    // MARK: - Pack reinstall

    func testAPackReinstallCompletedOnSidesCAndCPrime() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let reporter = RecordingOperationReporter()
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: true, reporter: reporter) { _ in }

        _ = try await runCompleted(
            .packReinstall,
            invocation: CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: true),
            recordedCommand: reporter.items.first?.cliCommand,
            fixture: { root in
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("home"), withIntermediateDirectories: true
                )
                let environments = pack.toolRequirements.map(\.environment)
                try ManagedToolsStandInConda.make(
                    storageRoot: Self.storageRoot(of: root), current: [], outdated: environments, templates: environments
                )
            }
        )
        XCTAssertEqual(reporter.items.count, 1, "the CLI route opens one row for the reinstall")
    }
}
