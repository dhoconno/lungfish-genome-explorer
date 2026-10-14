// ManagedToolsCLIGUIParityReplayTests+Completed.swift - The managed tools commands run to their end on sides A, C and C'
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3b (family L10, panel decisions C10 and C4, QA 4). The cancel cases in
// ManagedToolsCLIGUIParityReplayTests end every side cancelled. These cases run each side to its end
// against a stand-in micromamba that finishes (ManagedToolsStandInConda), and compare the roots the
// sides leave with kind `.managedPlan`.
//
// - Side A is the in-process route at the base. The Update Tools sheet runs the reconciler in this
//   process, and the Plugin Manager reinstalls the pack through `PluginPackStatusService`, both under
//   `ManagedToolsRouteSettings.testOverride = .legacy`.
// - Side C is the argv the L10 runner builds, run by the built `lungfish-cli` through the app's
//   transport launcher, with the root's environment. Side C' is the command the row recorded.
//
// The harness's own `run` replays the recorded command with the root of side C rebased, and refuses a
// command that names no path under that root. These commands name none, because the storage root
// travels in the environment as for every route, so the cases run the three sides themselves and hand
// the runs to `harness.evaluate`.
//
// The differences of A against C that the declared list holds, with where each is checked.
//
// 1. Rows. The in-process Update Tools run opens a parent row and a row for every item through the
//    reconciler's sink, with no command, where the CLI route opens one row whose command names the
//    chosen items. Checked by the row assertions in each case, since a row is not a file of a root.
// 2. Records. The CLI leaves write the pack record and the dependency record of their own process,
//    where the in-process pack route writes none. Declared below, as the files and values that differ.
// 3. Cancel. The in-process route cannot stop micromamba and the sheet has no Cancel. The cancel
//    cases of ManagedToolsCLIGUIParityReplayTests cover the CLI route on sides C and C'.
// 4. A database that cannot be updated in place shows a notice in process and a failed row on the CLI
//    route. The built CLI has no archive stand-in, so ManagedToolLeavesLiveConformanceTests covers it.
// 5. A pack's per-requirement progress feeds the row log in process, and the CLI route shows the
//    leaf's progress messages. Checked by the pack case's row assertion.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// The rows the reconciler opens through its sink on the in-process route.
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

    /// The differences of A against C, each counted. The list only shrinks.
    static let declared: [RouteParityDeclaredDifference<CompletedCase>] = [
        RouteParityDeclaredDifference(
            [.updateTools: 1],
            "differs: storage/provenance/dependencies/settled-<ANY>.lungfish-provenance.json at runtimeIdentity.executablePath",
            reason: "The reconciler writes the Update Tools record on both routes, and its runtime identity names the process that ran it, the app on the in-process route and lungfish-cli on the CLI route.",
            closedBy: "the phase that removes the in-process route (2.11)"
        ),
        RouteParityDeclaredDifference(
            [.packReinstall: 1],
            "only in C: storage/provenance/packs/settled-<ANY>.lungfish-provenance.json",
            reason: "The in-process pack route writes no record. conda install --pack writes one for every run, install or reinstall (lane A52 M2).",
            closedBy: "the phase that removes the in-process route (2.11)"
        ),
    ]

    // MARK: - Wall-clock values and ids of the managed state files

    /// The kind `.managedPlan` gives every file the roots mask alone (docs/contracts/CLI-EQUIVALENCE.md,
    /// "plans get the roots and run wall time masks alone"). The managed state files hold the time
    /// and ids of their run, which that policy leaves as written. The receipt's `installedAt` and
    /// `updatedAt`, the pack status cache's `timestamp` and file `mtime`s, a record's `createdAt`,
    /// `startedAt`, `completedAt` and UUIDs, and the minute a record's file name starts with, differ
    /// between any two runs of one command. C against C' declares nothing, so the clock alone would
    /// fail two runs of the same command.
    ///
    /// This settles each side's root the same way before the comparison. A value becomes `<TIME>` or
    /// `<ID>` where it is, so a key one route does not write still differs, and a record's stamp
    /// becomes `settled`. Nothing else is touched. The executable a record names stays, because which
    /// process wrote the record is a difference of the routes. It is the mask a reviewed change to the
    /// contract's table would add for managed state, and it goes when that change lands.
    static func settleWallClock(in root: URL) throws {
        let fileManager = FileManager.default
        let storage = storageRoot(of: root)
        let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        func settled(_ value: Any, times: Set<String>, ids: Set<String>) -> Any {
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, pair in
                    if times.contains(pair.key) {
                        result[pair.key] = "<TIME>"
                    } else if ids.contains(pair.key), let text = pair.value as? String,
                              text.range(of: uuidPattern, options: .regularExpression) != nil {
                        result[pair.key] = "<ID>"
                    } else {
                        result[pair.key] = settled(pair.value, times: times, ids: ids)
                    }
                }
            }
            if let array = value as? [Any] { return array.map { settled($0, times: times, ids: ids) } }
            if let text = value as? String {
                return text.replacingOccurrences(of: "mtime=[0-9.]+", with: "mtime=<TIME>", options: .regularExpression)
            }
            return value
        }
        func rewrite(_ url: URL, times: Set<String>, ids: Set<String>) throws {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let data = try JSONSerialization.data(
                withJSONObject: settled(value, times: times, ids: ids), options: [.sortedKeys, .prettyPrinted]
            )
            try data.write(to: url)
        }
        for relative in ["dependency-receipt.json", "conda/cache/plugin-pack-statuses.json"] {
            let url = storage.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path) {
                try rewrite(url, times: ["installedAt", "updatedAt", "timestamp"], ids: [])
            }
        }
        let provenance = storage.appendingPathComponent("provenance", isDirectory: true)
        for folder in (try? fileManager.contentsOfDirectory(atPath: provenance.path)) ?? [] {
            let directory = provenance.appendingPathComponent(folder, isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let url = directory.appendingPathComponent(name)
                try rewrite(url, times: ["createdAt", "startedAt", "completedAt"], ids: ["id"])
                guard let stamp = name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}-"#, options: .regularExpression) else { continue }
                try fileManager.moveItem(at: url, to: directory.appendingPathComponent("settled-" + name[stamp.upperBound...]))
            }
        }
    }

    // MARK: - Running a case

    /// Runs `sideA` in root A, the argv `invocation` on side C and the command the row recorded on
    /// side C', each in a root that started as a copy of the fixture, then compares the three.
    func runCompleted(
        _ parityCase: CompletedCase,
        invocation: CLIManagedToolsRunner.Invocation,
        recordedCommand command: String?,
        fixture: (URL) throws -> Void,
        sideA: (URL) async throws -> RouteParitySideOutcome
    ) async throws -> RouteParityResult {
        XCTAssertEqual(command, invocation.recordedCommand, "the row records the argv the runner runs")
        let fileManager = FileManager.default
        let caseRoot = scratch.appendingPathComponent("completed-\(parityCase)", isDirectory: true)
        try? fileManager.removeItem(at: caseRoot)
        let rootA = RouteParityHarness.root(of: .a, in: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fixture(rootA)
        for root in [rootC, rootCPrime] {
            try fileManager.copyItem(at: rootA, to: root)
        }

        let runA = RouteParitySideRun(side: .a, root: rootA, outcome: try await sideA(rootA))
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

        for root in [rootA, rootC, rootCPrime] {
            try Self.settleWallClock(in: root)
        }
        let runs = RouteParityRuns(caseRoot: caseRoot, a: runA, c: runC, cPrime: runCPrime)
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        return result
    }

    /// The conda manager of a side's root, as the built CLI builds its own: no bundled micromamba, so
    /// the installed copy under the conda root is used, and no shared package cache.
    func condaManager(in root: URL) -> CondaManager {
        CondaManager(
            rootPrefix: Self.storageRoot(of: root).appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )
    }

    // MARK: - Update Tools

    /// Side A of the Update Tools case. The sheet's view model runs the reconciler in this process.
    func updateToolsInProcess(root: URL, sink: RecordingDependencySink) async throws -> RouteParitySideOutcome {
        ManagedToolsRouteSettings.testOverride = .legacy
        defer { ManagedToolsRouteSettings.testOverride = nil }
        let storage = Self.storageRoot(of: root)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: scratch.appendingPathComponent("registry-A", isDirectory: true)
        )
        var services = ReconcilerServices.live(
            condaManager: condaManager(in: root), storageRoot: storage, metagenomicsRegistry: registry
        )
        // The built CLI reads the databases of its own storage root, which is empty.
        services.registryDatabaseVersions = { [:] }
        let reconciler = DependencyReconciler(
            manifest: ManagedToolLock.bundled,
            storageRoot: storage,
            services: services,
            appVersion: LungfishAppVersion.short,
            operationCenter: sink
        )
        let plan = try await reconciler.currentPlan()
        let viewModel = UpdateToolsSheetViewModel(plan: plan, reconciler: reconciler, storageRoot: storage)
        await viewModel.run()
        let failed = viewModel.failureSummary
        return RouteParitySideOutcome(
            end: failed == nil && viewModel.completed ? .completed : .failed,
            detail: failed ?? "in process"
        )
    }

    func testAnUpdateToolsRunCompletedOnSidesAAndCAndCPrime() async throws {
        let ids = ["pigz", "samtools"]
        let invocation = CLIManagedToolsRunner.updateTools(ids: ids)
        let reporter = RecordingOperationReporter()
        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools", detail: "\(ids.count) item(s)", cliCommand: invocation.recordedCommand, reporter: reporter
        ) { _ in }
        let sink = RecordingDependencySink()

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
            },
            sideA: { root in try await updateToolsInProcess(root: root, sink: sink) }
        )

        // Rows, difference 1 of the list above.
        XCTAssertEqual(reporter.items.count, 1, "the CLI route opens one row for the run")
        XCTAssertNotNil(reporter.items.first?.cliCommand, "and it records the command")
        XCTAssertGreaterThan(sink.started.count, 1, "the in-process route opens a parent row and one row per item")
    }

    // MARK: - Pack reinstall

    /// Side A of the pack case. The Plugin Manager's install call runs the pack service in this process.
    func packReinstallInProcess(root: URL, pack: PluginPack) async throws -> RouteParitySideOutcome {
        ManagedToolsRouteSettings.testOverride = .legacy
        defer { ManagedToolsRouteSettings.testOverride = nil }
        let service = PluginPackStatusService(condaManager: condaManager(in: root))
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        try await viewModel.installPackThroughRoute(
            pack: pack, reinstall: true, operationID: UUID(), provider: service
        ) { _ in }
        return RouteParitySideOutcome(end: .completed, detail: "in process")
    }

    func testAPackReinstallCompletedOnSidesAAndCAndCPrime() async throws {
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
            },
            sideA: { root in try await packReinstallInProcess(root: root, pack: pack) }
        )
        XCTAssertEqual(reporter.items.count, 1, "the CLI route opens one row for the reinstall")
    }
}
