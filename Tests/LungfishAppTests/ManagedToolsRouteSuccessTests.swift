// ManagedToolsRouteSuccessTests.swift - What the app does once the managed tools CLI route finishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3b (family L10, panel decisions C4 and C10). The route code of the Update Tools
// sheet, the Plugin Manager's pack install and its database update runs the CLI and then maps what
// the command left onto the screen. ManagedToolsCLIGUIParityReplayTests runs the built CLI. These
// tests run a stand-in `lungfish-cli` script through the runner's `cliURLOverride`, a shell script
// that records its argv, prints the events a real run prints (the transcripts under
// Tests/Fixtures/cli-events/commands) and leaves the files a real run leaves, so the mapping of a
// success and of a failure is checked without micromamba.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ManagedToolsRouteSuccessTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "managed-tools-route-success")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - The stand-in CLI

    private static func event(_ json: String) -> String { "echo '\(json)'" }
    private static let start = event(#"{"event":"start","message":"Starting","progress":0,"schemaVersion":2}"#)
    private static func progress(_ fraction: Double, _ message: String) -> String {
        event(#"{"event":"progress","message":"\#(message)","progress":\#(fraction),"schemaVersion":2}"#)
    }
    private static func complete(_ message: String) -> String {
        event(#"{"event":"complete","message":"\#(message)","output":"/tmp/managed-tools-result","outputs":["/tmp/managed-tools-result"],"progress":1,"schemaVersion":2}"#)
    }
    private static func failed(_ detail: String) -> String {
        event(#"{"detail":"\#(detail)","error":"0 updated, 1 failed","event":"failed","schemaVersion":2}"#) + "\nexit 2"
    }

    /// A stand-in CLI that records its argv, then runs `lines`.
    private func fakeCLI(_ lines: [String]) throws -> (cli: URL, argv: URL) {
        let argv = scratch.appendingPathComponent("argv.txt")
        let cli = scratch.appendingPathComponent("lungfish-cli")
        let body = (["#!/bin/sh", #"echo "$@" > "\#(argv.path)""#] + lines).joined(separator: "\n") + "\n"
        try body.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli, argv)
    }

    private func argvLine(_ argv: URL) throws -> String {
        try String(contentsOf: argv, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The row the route opened for `command`, and a clean shared center once the test ends.
    private func row(running command: String) throws -> OperationCenter.Item {
        try XCTUnwrap(OperationCenter.shared.items.first { $0.cliCommand == command }, "no row records \(command)")
    }

    private func clearRow(_ command: String) {
        for item in OperationCenter.shared.items where item.cliCommand == command {
            if item.state == .running { _ = OperationCenter.shared.complete(id: item.id, detail: "test") }
            OperationCenter.shared.clearItem(id: item.id)
        }
    }

    // MARK: - The Update Tools sheet

    private static let samtoolsSpec = "bioconda::samtools=1.24=h36b3a25_1"

    /// A reconciler over a one-tool lock whose environment exists once `marker` does, with the
    /// storage root `storage`. `sink` takes the rows the reconciler opens when it runs in process.
    private func makeReconciler(storage: URL, marker: URL, sink: DependencyOperationSink? = nil) -> DependencyReconciler {
        let manifest = ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [.init(id: "samtools", environment: "samtools", packageSpec: Self.samtoolsSpec, executables: ["samtools"], version: "1.24")],
            managedData: [], dependencySet: "2026.2", pipelines: [], databases: [],
            bootstrap: BootstrapSpec(micromamba: .init(version: "2.9.0-0", sha256: nil))
        )
        var services = ReconcilerServices.live(condaManager: .shared, storageRoot: storage)
        services.listEnvironments = {
            FileManager.default.fileExists(atPath: marker.path)
                ? ["samtools": [CondaMetaPackage(name: "samtools", version: "1.24", build: "h36b3a25_1", subdir: nil, channel: nil)]]
                : [:]
        }
        services.installedPackIDs = { [] }
        services.registryDatabaseVersions = { [:] }
        services.metagenomicsDatabaseVersions = { [:] }
        services.installedMicromambaVersion = { "2.9.0" }
        // A unit test never installs micromamba, whichever route runs the reconciler.
        services.installBootstrap = { _ in }
        return DependencyReconciler(manifest: manifest, storageRoot: storage, services: services, appVersion: "test", operationCenter: sink)
    }

    /// The receipt the command saves, prepared under its own root for the stand-in to copy into place.
    private func preparedReceipt(state: DependencyReceipt.EntryState) throws -> URL {
        let prepared = scratch.appendingPathComponent("prepared-\(state.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let receipt = DependencyReceipt(
            schemaVersion: DependencyReceipt.currentSchemaVersion, dependencySet: "2026.2", appVersion: "test",
            manifestHash: nil, updatedAt: Date(), synthesized: false,
            environments: ["samtools": .init(packageSpec: Self.samtoolsSpec, packID: "lungfish-tools", installedAt: Date(), state: state)],
            databases: [:], pipelines: [:], bootstrap: .init(micromambaVersion: "2.9.0")
        )
        _ = try DependencyReceiptStore(storageRoot: prepared).save(receipt)
        return prepared.appendingPathComponent("dependency-receipt.json")
    }

    private func runSheet(script: [String], receiptState: DependencyReceipt.EntryState, marker: URL) async throws
        -> (sheet: UpdateToolsSheetViewModel, argv: String, command: String)
    {
        let storage = scratch.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let receipt = try preparedReceipt(state: receiptState)
        let (cli, argv) = try fakeCLI([#"cp "\#(receipt.path)" "\#(storage.appendingPathComponent("dependency-receipt.json").path)""#] + script)
        let reconciler = makeReconciler(storage: storage, marker: marker)
        let plan = try await reconciler.currentPlan()
        XCTAssertEqual(plan.installEnvironments.map(\.environment), ["samtools"], "the plan holds the item before the run")
        let sheet = UpdateToolsSheetViewModel(plan: plan, reconciler: reconciler, storageRoot: storage)
        sheet.cliURLOverride = cli
        await sheet.run()
        let command = CLIManagedToolsRunner.updateTools(ids: ["samtools"]).recordedCommand
        return (sheet, try argvLine(argv), command)
    }

    func testTheSheetMapsASuccessfulCLIRunToDoneItemsTheReceiptAndACompletedRow() async throws {
        let marker = scratch.appendingPathComponent("samtools-installed")
        let run = try await runSheet(
            script: [
                #"touch "\#(marker.path)""#, Self.start,
                Self.progress(0.5, "samtools: Solving samtools"), Self.progress(0.99, "samtools: samtools created"),
                Self.complete("Updated 1 item(s) to 2026.2"),
            ],
            receiptState: .installed, marker: marker
        )
        defer { clearRow(run.command) }

        XCTAssertEqual(run.argv, "tools update --apply --yes --only samtools --format json")
        XCTAssertEqual(run.sheet.itemStatus["samtools"], .done)
        XCTAssertNil(run.sheet.failureSummary)
        XCTAssertTrue(run.sheet.completed)
        XCTAssertFalse(run.sheet.isRunning)
        XCTAssertEqual(run.sheet.resultReceipt?.environments["samtools"]?.state, .installed)
        let row = try row(running: run.command)
        XCTAssertEqual(row.state, .completed)
        XCTAssertTrue(row.detail.contains("Updated 1 item(s)"), "the row ends on the command's complete message: \(row.detail)")
    }

    func testTheSheetMapsAFailedCLIRunToAFailedItemTheSummaryAndAFailedRow() async throws {
        let marker = scratch.appendingPathComponent("samtools-installed")
        let run = try await runSheet(
            script: [Self.start, Self.progress(0.5, "samtools: Solving samtools"), Self.failed("samtools: samtools does not solve")],
            receiptState: .failed, marker: marker
        )
        defer { clearRow(run.command) }

        guard case .failed(let message)? = run.sheet.itemStatus["samtools"] else {
            return XCTFail("the item is still in the plan, so it failed: \(String(describing: run.sheet.itemStatus["samtools"]))")
        }
        XCTAssertTrue(message.contains("does not solve"), "the item carries the command's words: \(message)")
        XCTAssertEqual(run.sheet.failureSummary, "1 item did not finish: samtools")
        XCTAssertTrue(run.sheet.completed)
        XCTAssertEqual(run.sheet.resultReceipt?.environments["samtools"]?.state, .failed)
        XCTAssertEqual(try row(running: run.command).state, .failed)
    }

    // MARK: - An empty selection

    /// The sheet over a plan that holds only the bootstrap update, so its selection names no item. A
    /// recording sink sits on the reconciler to show whether the run opened an in-process row.
    private func runEmptySelection(script: [String]) async throws
        -> (sheet: UpdateToolsSheetViewModel, sink: RecordingDependencySink, argv: String?, command: String)
    {
        let storage = scratch.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        // Samtools exists, so the plan after the command holds nothing. The command leaves the receipt.
        let marker = scratch.appendingPathComponent("samtools-installed")
        try Data().write(to: marker)
        let receipt = try preparedReceipt(state: .installed)
        let (cli, argv) = try fakeCLI([#"cp "\#(receipt.path)" "\#(storage.appendingPathComponent("dependency-receipt.json").path)""#] + script)
        let sink = RecordingDependencySink()
        let reconciler = makeReconciler(storage: storage, marker: marker, sink: sink)
        let plan = ReconciliationPlan(
            installEnvironments: [], reinstallEnvironments: [], removeEnvironments: [], databaseUpdates: [],
            pipelinePrefetch: [], bootstrapUpdate: .init(currentVersion: "2.8.0", targetVersion: "2.9.0"),
            targetDependencySet: "2026.2", estimatedDownloadBytes: 0
        )
        let sheet = UpdateToolsSheetViewModel(plan: plan, reconciler: reconciler, storageRoot: storage)
        sheet.cliURLOverride = cli
        XCTAssertTrue(CLIManagedToolsRunner.itemIDs(of: sheet.selection(), in: plan).isEmpty, "the selection names no item")
        await sheet.run()
        return (sheet, sink, try? argvLine(argv), CLIManagedToolsRunner.updateToolsRequiredOnly().recordedCommand)
    }

    /// Lane A52's review, Fix 3 c. A plan that holds only the bootstrap update or the pipeline prefetch
    /// names no item, and the CLI route used to run the reconciler in process for it, so its rows
    /// recorded no command. Required items are always selected and the bootstrap and prefetch always
    /// run, so `tools update --apply --yes --required-only` does that work.
    func testAnEmptySelectionRunsTheRequiredOnlyCommand() async throws {
        let run = try await runEmptySelection(script: [
            Self.start, Self.progress(0.5, "micromamba: Updating micromamba"), Self.complete("Updated 0 item(s) to 2026.2"),
        ])
        defer { clearRow(run.command) }

        XCTAssertTrue(run.sink.started.isEmpty, "the CLI route opens no in-process row: \(run.sink.started)")
        XCTAssertEqual(run.argv, "tools update --apply --yes --required-only --format json")
        XCTAssertTrue(run.sheet.completed)
        XCTAssertNil(run.sheet.failureSummary)
        XCTAssertEqual(OperationCenter.shared.items.filter { $0.cliCommand == run.command }.count, 1, "one row records the command")
        let row = try row(running: run.command)
        XCTAssertEqual(row.state, .completed)
        XCTAssertTrue(row.detail.contains("Updated 0 item(s)"), "the row ends on the command's complete message: \(row.detail)")
    }

    /// The result of a sheet is built from its items, and an empty selection has none, so a failed
    /// command must end the sheet failed through the command's own words.
    func testAnEmptySelectionThatFailsEndsTheSheetFailedWithTheCommandsWords() async throws {
        let run = try await runEmptySelection(script: [Self.start, Self.failed("micromamba does not update")])
        defer { clearRow(run.command) }

        XCTAssertEqual(run.argv, "tools update --apply --yes --required-only --format json")
        XCTAssertTrue(run.sheet.completed)
        XCTAssertTrue(
            run.sheet.failureSummary?.contains("does not update") == true,
            "the summary carries the command's words: \(String(describing: run.sheet.failureSummary))"
        )
        XCTAssertEqual(try row(running: run.command).state, .failed)
    }

    // MARK: - The Plugin Manager

    private actor CountingProvider: PluginPackStatusProviding {
        private(set) var invalidations = 0
        func visibleStatuses() async -> [PluginPackStatus] { [] }
        func status(for pack: PluginPack) async -> PluginPackStatus {
            PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
        }
        func invalidateVisibleStatusesCache() async { invalidations += 1 }
        func install(pack: PluginPack, reinstall: Bool, progress: (@Sendable (PluginPackInstallProgress) -> Void)?) async throws {
            XCTFail("the CLI route does not install in process")
        }
    }

    private func beginPackRow(_ pack: PluginPack, reinstall: Bool) throws -> UUID {
        var started: UUID?
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: reinstall) { started = $0 }
        return try XCTUnwrap(started)
    }

    func testThePackRouteRunsTheInstallCommandShowsItsProgressAndForgetsTheCachedStatuses() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let command = CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: true).recordedCommand
        defer { clearRow(command) }
        let id = try beginPackRow(pack, reinstall: true)
        let (cli, argv) = try fakeCLI([Self.start, Self.progress(0.5, "Creating mafft"), Self.complete("MSA ready")])
        let provider = CountingProvider()
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)

        try await viewModel.installPackThroughRoute(
            pack: pack, reinstall: true, operationID: id, provider: provider, cliURLOverride: cli
        )

        XCTAssertEqual(try argvLine(argv), "conda install --pack multiple-sequence-alignment --reinstall --format json")
        let invalidations = await provider.invalidations
        XCTAssertEqual(invalidations, 1, "the status service forgets what it cached before the caller reads the status")
        XCTAssertEqual(viewModel.packProgressMessage[pack.id], "Creating mafft", "the row's progress message reaches the pack card")
    }

    func testThePackRouteRethrowsTheCommandsFailureAndStillForgetsTheCachedStatuses() async throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
        let command = CLIManagedToolsRunner.installPack(packID: pack.id, reinstall: false).recordedCommand
        defer { clearRow(command) }
        let id = try beginPackRow(pack, reinstall: false)
        let (cli, argv) = try fakeCLI([Self.start, Self.failed("mafft does not run")])
        let provider = CountingProvider()
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)

        do {
            try await viewModel.installPackThroughRoute(
                pack: pack, reinstall: false, operationID: id, provider: provider, cliURLOverride: cli
            )
            XCTFail("a failed command throws")
        } catch is CancellationError {
            XCTFail("a failure is not a cancel")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mafft does not run"), "\(error.localizedDescription)")
        }
        XCTAssertEqual(try argvLine(argv), "conda install --pack multiple-sequence-alignment --format json")
        let invalidations = await provider.invalidations
        XCTAssertEqual(invalidations, 1)
    }

    func testTheDatabaseRouteRunsTheCommandAndReadsTheManifestTheCommandSaved() async throws {
        let appBase = scratch.appendingPathComponent("app-registry", isDirectory: true)
        let cliBase = scratch.appendingPathComponent("cli-registry", isDirectory: true)
        let folder = cliBase.appendingPathComponent("kraken2/lab-index", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "payload".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: appBase, withIntermediateDirectories: true)
        // The manifest the command saves, made by a registry of its own and copied into place by the stand-in.
        _ = try await MetagenomicsDatabaseRegistry(baseDirectory: cliBase).seedRowThroughManifest(at: folder, name: "Lab Index")
        let app = MetagenomicsDatabaseRegistry(baseDirectory: appBase)
        try await app.loadIfNeeded()
        let before = try await app.database(named: "Lab Index")
        XCTAssertNil(before, "the app's registry has not seen the database yet")

        let manifest = "metagenomics-db-registry.json"
        let (cli, argv) = try fakeCLI([
            #"cp "\#(cliBase.appendingPathComponent(manifest).path)" "\#(appBase.appendingPathComponent(manifest).path)""#,
            Self.start, Self.progress(0.5, "Downloading Viral"), Self.complete("Updated Viral"),
        ])
        let invocation = CLIManagedToolsRunner.updateDatabase(catalogID: "kraken2-viral")
        defer { clearRow(invocation.recordedCommand) }
        var started: UUID?
        PluginManagerViewModel.beginDatabaseUpdateOperation(name: "Lab Index", catalogID: "kraken2-viral", targetVersion: "2") { started = $0 }
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        var fractions: [Double] = []
        let seen = Seen()

        try await viewModel.updateDatabaseThroughRoute(
            catalogID: "kraken2-viral",
            operationID: try XCTUnwrap(started),
            registry: app,
            cliURLOverride: cli
        ) { fraction, _ in seen.append(fraction) }
        fractions = seen.values

        XCTAssertEqual(try argvLine(argv), "conda db update kraken2-viral --yes --format json")
        let after = try await app.database(named: "Lab Index")
        XCTAssertEqual(after?.status, .ready, "the route read the manifest the command saved")
        XCTAssertTrue(fractions.contains(0.5), "the command's progress reaches the caller: \(fractions)")
    }

    private final class Seen: Sendable {
        private let state = Mutex<[Double]>([])
        func append(_ value: Double) { state.withLock { $0.append(value) } }
        var values: [Double] { state.withLock { $0 } }
    }
}
