// ManagedToolsCLIGUIParityReplayTests.swift - The managed tools and packs commands cancelled through the app's transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3 (family L10, panel decisions C10 and C4, QA 4), on lane Q30's
// `RouteParityHarness` with kind `.managedPlan`. Side C runs the argv the L10 runner builds for the
// Update Tools run and the Plugin Manager's pack reinstall through the app's own transport
// (`CLIProcessLauncher` and `CLIRunCancellation`, the code `CLISubprocessTransport` runs), against a
// stand-in micromamba that never finishes. Side C' replays the command the row recorded. Each side
// is cancelled once micromamba and its worker are at work, and lane S30's check passes on both. The
// command exits 125 inside `CLIProcessLauncher.operationGrace`, its record reads cancelled and no
// process of its tree is left. The record of the run is the part of the plan the harness reads.
//
// Side A, the in-process route, is not cancelled here. `CondaManager` runs micromamba to its end when
// its caller is cancelled, so the old route cannot be cancelled at this point at all, which is the
// difference between the routes that keeps the hidden key (decision C4). The cases that run every
// side to its end, side A included, are in ManagedToolsCLIGUIParityReplayTests+Completed.swift. The
// database update has no stand-in on the built CLI, so its cancel is
// `ManagedToolLeavesLiveConformanceTests`.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ManagedToolsCLIGUIParityReplayTests: XCTestCase {
    var scratch: URL!
    var cli: URL!
    var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "managed-tools-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(
            cliBinary: cli,
            kind: .managedPlan,
            replayTimeout: .seconds(120),
            environment: { Self.environment(for: $0) }
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - A root and its stand-in micromamba

    nonisolated static func storageRoot(of root: URL) -> URL {
        root.appendingPathComponent("storage", isDirectory: true)
    }

    /// The variables each CLI run gets for the side `root`: its own storage root, conda root and home.
    nonisolated static func environment(for root: URL) -> [String: String] {
        [
            "LUNGFISH_STORAGE_ROOT": storageRoot(of: root).path,
            "LUNGFISH_CONDA_ROOT": storageRoot(of: root).appendingPathComponent("conda").path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
        ]
    }

    /// Builds the fixture of a side: a conda root whose micromamba answers its version and then
    /// records its pid, starts a worker and waits.
    nonisolated private static func makeFixture(in root: URL) throws {
        let fileManager = FileManager.default
        let bin = storageRoot(of: root).appendingPathComponent("conda/bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        let lockVersion = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.9.0-0"
        let version = lockVersion.split(separator: "-").first.map(String.init) ?? lockVersion
        let micromamba = bin.appendingPathComponent("micromamba")
        // The pid files sit beside the storage root, so they differ per side without the script
        // knowing it. The script reads its own path from $0.
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "\(version)"; exit 0; fi
        side=$(cd "$(dirname "$0")/../../.." && pwd)
        echo $$ > "$side/micromamba.pid"
        /bin/sh -c 'echo $$ > "'"$side"'/worker.pid"; exec /bin/sleep 300' &
        wait
        """.write(to: micromamba, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
    }

    /// Whether micromamba and its worker of the side `root` are at work.
    nonisolated private static func isAtWork(_ root: URL) -> Bool {
        ["micromamba.pid", "worker.pid"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// The status of the newest record under `provenance/<folder>` of the side `root`.
    nonisolated private static func recordStatus(in root: URL, folder: String) throws -> String? {
        let directory = storageRoot(of: root).appendingPathComponent("provenance/\(folder)", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
            .sorted()
        guard let newest = names.last else { return nil }
        return try ProvenanceEnvelopeReader.load(fromSidecar: directory.appendingPathComponent(newest))?.status.rawValue
    }

    // MARK: - Cases

    /// Runs `invocation` on side C through the real transport and cancels it at work, replays the
    /// command `command` the row recorded on side C' and cancels that too, then checks both with
    /// S30's assertions.
    private func assertCancelledOnSidesCAndCPrime(
        _ name: String,
        invocation: CLIManagedToolsRunner.Invocation,
        recordedCommand command: String?,
        recordFolder: String
    ) async throws {
        XCTAssertEqual(command, invocation.recordedCommand, "the row records the argv the runner runs")
        let caseRoot = scratch.appendingPathComponent(name, isDirectory: true)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try Self.makeFixture(in: rootC)
        try Self.makeFixture(in: rootCPrime)
        let cancel = RouteParityCancel(
            when: { Self.isAtWork($0) },
            record: { try Self.recordStatus(in: $0, folder: recordFolder) }
        )

        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: invocation.argv,
            timeout: .seconds(120),
            environment: Self.environment(for: rootC),
            cancelWhen: { cancel.isReached(rootC) }
        )
        let sideC = RouteParitySideRun(
            side: .c,
            root: rootC,
            outcome: RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command, cancel: run.cancel)
        )
        XCTAssertEqual(sideC.outcome.end, .cancelled, "side C: \(run.detail) \(run.stderr)")
        await RouteParityHarness.assertCancelled(sideC, cancel)

        // Side C'. The harness's own replay rebases the root of side C in the recorded command, and
        // these commands name no path of it, because the storage root travels in the environment as
        // for every route. So the recorded line is parsed back and run on the root of side C' with
        // that root's environment, through the same transport.
        let replayed = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(command))
        XCTAssertEqual(replayed, invocation.argv, "the recorded command is the argv the runner runs")
        let replay = await RouteParityHarness.runCLI(
            cli,
            arguments: replayed,
            timeout: .seconds(120),
            environment: Self.environment(for: rootCPrime),
            cancelWhen: { cancel.isReached(rootCPrime) }
        )
        let sideCPrime = RouteParitySideRun(
            side: .cPrime,
            root: rootCPrime,
            outcome: RouteParitySideOutcome(end: replay.end, detail: replay.detail, cancel: replay.cancel),
            replayedArguments: [replayed]
        )
        XCTAssertEqual(sideCPrime.outcome.end, .cancelled, "side C': \(sideCPrime.outcome.detail)")
        await RouteParityHarness.assertCancelled(sideCPrime, cancel)
    }

    func testAPackReinstallCancelledThroughTheTransportEndsCancelledOnSidesCAndCPrime() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "read-mapping"))
        let reporter = RecordingOperationReporter()
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: true, reporter: reporter) { _ in }
        try await assertCancelledOnSidesCAndCPrime(
            "pack-reinstall",
            invocation: CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: true),
            recordedCommand: reporter.items.first?.cliCommand,
            recordFolder: "packs"
        )
    }

    func testAnUpdateToolsRunCancelledThroughTheTransportEndsCancelledOnSidesCAndCPrime() async throws {
        let ids = ["samtools", "pigz"]
        let reporter = RecordingOperationReporter()
        let invocation = CLIManagedToolsRunner.updateTools(ids: ids)
        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools", detail: "\(ids.count) item(s)", cliCommand: invocation.recordedCommand, reporter: reporter
        ) { _ in }
        try await assertCancelledOnSidesCAndCPrime(
            "update-tools",
            invocation: invocation,
            recordedCommand: reporter.items.first?.cliCommand,
            recordFolder: "dependencies"
        )
    }
}
