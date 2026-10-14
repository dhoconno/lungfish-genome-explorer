// DemoProjectsDownloadParityReplayTests.swift - The Demo Projects window's download, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M4, panel decisions C4, C9 and G5, on lane Q30's harness. One demo project downloads into
// the folder of the window on three sides that start as copies of one empty folder.
//
// - Side A is the install the app ran in its own process before lane A45, `DemoProjectInstaller` called directly
//   on the folder of the root. The window's in-process path and its hidden key went with the flip (C4), so the
//   installer is what is left of it.
// - Side C is the window's download, `lungfish-cli demo fetch <id> --dest <folder> --format json` launched
//   through `CLISubprocessTransport`, with the line the row recorded.
// - Side C' is the harness's replay of the row's recorded command.
//
// Both routes read one loopback server (`DemoArchiveStandIn`). The window names the project in its list with the
// archive on the server, and the child reads the same list from the environment and the origin of the server from
// the environment, so no side reaches GitHub. The class launches the built lungfish-cli, so its name ends in
// ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DemoProjectsDownloadParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case freshInstall
    }

    /// Each way side C differs from side A with BIO's reason, as measured. None. The class was measured twice, in two
    /// processes, with this list empty and no mask, and the only difference between A and C was the install time
    /// in `.lgedemo.json`, a clock value the installer writes to the second. The contract now masks it by path
    /// (`Masks.demoInstallClock`, CLI-EQUIVALENCE.md), and A against C and C against C' are empty in every run.
    static let declared: [RouteParityDeclaredDifference<Case>] = []

    func testAFreshInstallInstallsTheSameProjectOnBothRoutes() async throws {
        try await assertParity(.freshInstall)
    }

    func assertParity(_ parityCase: Case) async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "demo-row-parity")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let standIn = try DemoArchiveStandIn.start(in: root.appendingPathComponent("served", isDirectory: true), payloadBytes: 50_000)
        addTeardownBlock { standIn.stop() }
        var set = standIn.environment
        set[DemoLocationOptions.manifestVariable] = standIn.manifestURL.path
        let saved = ProcessEnvironmentOverride(set: set, unset: ["NCBI_API_KEY"])
        addTeardownBlock { saved.restore() }
        let defaults = makeTestDefaultsSuite(prefix: "DemoProjectsDownloadParityReplayTests").defaults

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: { try FileManager.default.createDirectory(at: Self.installed(in: $0), withIntermediateDirectories: true) },
            sideA: { await Self.installDirectly(in: $0, standIn: standIn) },
            sideC: { await Self.window(in: $0, standIn: standIn, cli: cli, defaults: defaults) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")

        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            let project = Self.installed(in: run.root).appendingPathComponent(DemoArchiveStandIn.projectFolderName)
            XCTAssertEqual(DemoProjectInstaller.readRecord(inProjectAt: project)?.id, DemoArchiveStandIn.projectID, "side \(run.side)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["demo", "fetch", DemoArchiveStandIn.projectID]])
    }

    // MARK: - Sides

    static func installed(in root: URL) -> URL {
        root.appendingPathComponent("Installed", isDirectory: true)
    }

    /// Side A. The installer the window used in the app process, called on the folder of `root` with the project
    /// the window would name, and how it ended. It records no command.
    static func installDirectly(in root: URL, standIn: DemoArchiveStandIn) async -> RouteParitySideOutcome {
        do {
            _ = try await DemoProjectInstaller(appVersion: "2026.9.44")
                .install(standIn.project, into: installed(in: root), replaceExisting: false) { _ in }
            return RouteParitySideOutcome(end: .completed, detail: "DemoProjectInstaller installed the project", recordedCommand: nil)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: nil)
        }
    }

    /// Side C. One download of the project into the folder of `root` through the window, and how it ended. The row
    /// records the command, which side C' replays.
    static func window(
        in root: URL, standIn: DemoArchiveStandIn, cli: URL, defaults: UserDefaults
    ) async -> RouteParitySideOutcome {
        let store = DemoProjectLocationStore(defaults: defaults, homeDirectory: root)
        store.directory = installed(in: root)
        let reporter = ParityReporter()
        let project = standIn.project
        let environment = DemoProjectsEnvironment(
            loadManifest: { DemoProjectManifest(projects: [project]) },
            installer: DemoProjectInstaller(appVersion: "2026.9.44"),
            locationStore: store,
            operations: reporter,
            openProject: { _ in reporter.opened = true },
            revealInFinder: { _ in },
            openURL: { _ in },
            isProjectOpen: { _ in false },
            cliURL: cli
        )
        let model = DemoProjectsViewModel(environment: environment)
        model.download(project, replaceExisting: false)
        let ended = await LungfishTestSupport.waitUntil(timeout: .seconds(120)) { reporter.opened || !reporter.failures.isEmpty }
        let detail = reporter.failures.isEmpty ? "the window opened the project" : reporter.failures.joined(separator: " | ")
        guard ended else {
            return RouteParitySideOutcome(end: .failed, detail: "the window never ended", recordedCommand: reporter.begunCommands.first)
        }
        return RouteParitySideOutcome(
            end: reporter.opened ? .completed : .failed, detail: detail, recordedCommand: reporter.begunCommands.first)
    }
}

/// What the window reports to Operations, kept for the side's outcome.
@MainActor
private final class ParityReporter: DemoProjectOperationReporting {
    private(set) var begunCommands: [String] = []
    private(set) var failures: [String] = []
    var opened = false

    func begin(title: String, detail: String, cliCommand: String) -> UUID? {
        begunCommands.append(cliCommand)
        return UUID()
    }

    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void) {}
    func report(id: UUID, phase: DemoProjectInstallPhase) {}
    func complete(id: UUID, projectURL: URL) {}
    func fail(id: UUID, message: String) { failures.append(message) }
    func acknowledgeCancellation(id: UUID) {}
}
