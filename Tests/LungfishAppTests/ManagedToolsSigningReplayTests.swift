// ManagedToolsSigningReplayTests.swift - The managed tools commands keep their signatures when the launch moves to the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L10 (the ruling of the A52 whole-lane review, Q6). The cases of
// ManagedToolsCLIGUIParityReplayTests+Completed run every side with no signing key. These two run the same
// Update Tools and pack reinstall sides again with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key
// under the case root, and fail when the CLI route leaves a record unsigned that the in-process route signs, or
// leaves the record the result opens first unsigned. The sides are not compared against the declared list,
// because a signed record adds two files to each root and the declared counts are for runs with no key.
//
// - Update Tools. The reconciler writes the run's dependency record through the default signer on both routes
//   (`DependencyReconcilerProvenance`), so both routes sign it.
// - Pack reinstall. The in-process route writes no record, and the CLI pack leaf writes its record through
//   `ManagedToolLeafSupport`, which takes the default signer. The pack record is the record the result opens.
//
// It launches the built lungfish-cli and sets process variables, so its name ends in ReplayTests and it runs in
// the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ManagedToolsSigningReplayTests: XCTestCase {
    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "managed-tools-signing")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(
            cliBinary: cli,
            kind: .managedPlan,
            replayTimeout: .seconds(120),
            environment: { ManagedToolsCLIGUIParityReplayTests.environment(for: $0) }
        )
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    // MARK: - Running a case with a key

    /// The sides of ManagedToolsCLIGUIParityReplayTests+Completed with the key in the environment. The command
    /// the row recorded names no path under root C, so the harness's own `run` cannot replay it, and the case
    /// replays it as that class does.
    private func runSigned(
        _ name: String,
        invocation: CLIManagedToolsRunner.Invocation,
        recordedCommand command: String?,
        fixture: (URL) throws -> Void,
        sideA: (URL) async throws -> RouteParitySideOutcome
    ) async throws -> RouteParityRuns {
        XCTAssertEqual(command, invocation.recordedCommand, "the row records the argv the runner runs")
        let fileManager = FileManager.default
        let caseRoot = scratch.appendingPathComponent("signed-\(name)", isDirectory: true)
        try? fileManager.removeItem(at: caseRoot)
        let rootA = RouteParityHarness.root(of: .a, in: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fixture(rootA)
        for root in [rootC, rootCPrime] {
            try fileManager.copyItem(at: rootA, to: root)
        }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: caseRoot))
        defer { saved.restore() }

        let runA = RouteParitySideRun(side: .a, root: rootA, outcome: try await sideA(rootA))
        let run = await RouteParityHarness.runCLI(
            cli, arguments: invocation.argv, timeout: .seconds(120),
            environment: ManagedToolsCLIGUIParityReplayTests.environment(for: rootC)
        )
        let runC = RouteParitySideRun(
            side: .c, root: rootC,
            outcome: RouteParitySideOutcome(end: run.end, detail: "\(run.detail) \(run.stderr)", recordedCommand: command)
        )
        let replayed = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(command))
        let replay = await RouteParityHarness.runCLI(
            cli, arguments: replayed, timeout: .seconds(120),
            environment: ManagedToolsCLIGUIParityReplayTests.environment(for: rootCPrime)
        )
        let runCPrime = RouteParitySideRun(
            side: .cPrime, root: rootCPrime,
            outcome: RouteParitySideOutcome(end: replay.end, detail: "\(replay.detail) \(replay.stderr)"),
            replayedArguments: [replayed]
        )
        return RouteParityRuns(caseRoot: caseRoot, a: runA, c: runC, cPrime: runCPrime)
    }

    /// The newest record of a run in `storage/provenance/<folder>` of the side `root`. The path of a record that
    /// is not there still names the folder, so the assertion reports a missing record.
    private nonisolated static func newestRecord(in root: URL, folder: String) -> URL {
        let directory = ManagedToolsCLIGUIParityReplayTests.storageRoot(of: root)
            .appendingPathComponent("provenance/\(folder)", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
            .sorted()
        return directory.appendingPathComponent(names.last ?? "no-record.lungfish-provenance.json")
    }

    private func assertCompleted(_ runs: RouteParityRuns) {
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    private func conda(in root: URL) -> CondaManager {
        CondaManager(
            rootPrefix: ManagedToolsCLIGUIParityReplayTests.storageRoot(of: root).appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )
    }

    private nonisolated static func homeFolder(in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    // MARK: - Update Tools

    func testAnUpdateToolsRunLosesNoSignatureOnTheCLIRoute() async throws {
        let ids = ["pigz", "samtools"]
        let invocation = CLIManagedToolsRunner.updateTools(ids: ids)
        let reporter = RecordingOperationReporter()
        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools", detail: "\(ids.count) item(s)", cliCommand: invocation.recordedCommand, reporter: reporter
        ) { _ in }
        let sink = RecordingDependencySink()

        let runs = try await runSigned(
            "update-tools",
            invocation: invocation,
            recordedCommand: reporter.items.first?.cliCommand,
            fixture: { root in
                try Self.homeFolder(in: root)
                let others = ManagedToolLock.bundled.tools.map(\.environment).filter { !ids.contains($0) }
                try ManagedToolsStandInConda.make(
                    storageRoot: ManagedToolsCLIGUIParityReplayTests.storageRoot(of: root),
                    current: others, outdated: ["pigz"], templates: ids
                )
            },
            sideA: { root in
                ManagedToolsRouteSettings.testOverride = .legacy
                defer { ManagedToolsRouteSettings.testOverride = nil }
                let storage = ManagedToolsCLIGUIParityReplayTests.storageRoot(of: root)
                let registry = MetagenomicsDatabaseRegistry(baseDirectory: scratch.appendingPathComponent("registry-A", isDirectory: true))
                var services = ReconcilerServices.live(condaManager: conda(in: root), storageRoot: storage, metagenomicsRegistry: registry)
                services.registryDatabaseVersions = { [:] }
                let reconciler = DependencyReconciler(
                    manifest: ManagedToolLock.bundled, storageRoot: storage, services: services,
                    appVersion: LungfishAppVersion.short, operationCenter: sink
                )
                let viewModel = UpdateToolsSheetViewModel(plan: try await reconciler.currentPlan(), reconciler: reconciler, storageRoot: storage)
                await viewModel.run()
                return RouteParitySideOutcome(
                    end: viewModel.failureSummary == nil && viewModel.completed ? .completed : .failed,
                    detail: viewModel.failureSummary ?? "in process"
                )
            }
        )
        assertCompleted(runs)
        let opening: @Sendable (URL) -> URL = { Self.newestRecord(in: $0, folder: "dependencies") }
        RouteParityHarness.assertNoSignatureLost(runs, opening: opening)
        await harness.assertSignaturesVerify(runs, opening: opening)
    }

    // MARK: - Pack reinstall

    func testAPackReinstallLosesNoSignatureOnTheCLIRoute() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let reporter = RecordingOperationReporter()
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: true, reporter: reporter) { _ in }

        let runs = try await runSigned(
            "pack-reinstall",
            invocation: CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: true),
            recordedCommand: reporter.items.first?.cliCommand,
            fixture: { root in
                try Self.homeFolder(in: root)
                let environments = pack.toolRequirements.map(\.environment)
                try ManagedToolsStandInConda.make(
                    storageRoot: ManagedToolsCLIGUIParityReplayTests.storageRoot(of: root),
                    current: [], outdated: environments, templates: environments
                )
            },
            sideA: { root in
                ManagedToolsRouteSettings.testOverride = .legacy
                defer { ManagedToolsRouteSettings.testOverride = nil }
                let service = PluginPackStatusService(condaManager: conda(in: root))
                let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
                try await viewModel.installPackThroughRoute(pack: pack, reinstall: true, operationID: UUID(), provider: service) { _ in }
                return RouteParitySideOutcome(end: .completed, detail: "in process")
            }
        )
        assertCompleted(runs)
        let opening: @Sendable (URL) -> URL = { Self.newestRecord(in: $0, folder: "packs") }
        RouteParityHarness.assertNoSignatureLost(runs, opening: opening)
        await harness.assertSignaturesVerify(runs, opening: opening)
    }
}
