// ManagedToolLeavesTests.swift - tools update --only, conda install --pack --reinstall, conda db update
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M2 (family L10, plan decisions C10, C5 and P2). The Update Tools sheet, the
// Plugin Manager's pack install and reinstall, and its database update run these three leaves under
// the app's cancel. Each leaf speaks events under `--format json`, records its run, and turns SIGTERM
// into a cancel that records the run as cancelled and exits 125. The SIGTERM checks here send the
// signal to the test process itself once the leaf is at work, because the leaf's handler is in place
// by then. The tests of the built CLI on `CLISIGTERMHarness` are in the report's Handoff.

import ArgumentParser
import Darwin
import Foundation
import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ManagedToolLeavesTests: XCTestCase {
    typealias Fixtures = ManagedToolLeafFixtures
    private var root: URL!
    private var savedStorageRoot: String?

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "managed-tool-leaves")
        savedStorageRoot = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
        CondaCommand.storageRootOverride = root
    }

    override func tearDownWithError() throws {
        CondaCommand.storageRootOverride = nil
        CondaCommand.packStatusServiceOverride = nil
        ToolsCommand.manifestOverride = nil
        ToolsCommand.servicesOverride = nil
        DbCommand.DbUpdateSubcommand.registryOverride = nil
        if let savedStorageRoot {
            setenv("LUNGFISH_STORAGE_ROOT", savedStorageRoot, 1)
        } else {
            unsetenv("LUNGFISH_STORAGE_ROOT")
        }
        TestTempDirectory.cleanup(root)
    }

    private func assertExit(_ expected: CLIExitCode, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("the leaf must exit \(expected)", file: file, line: line)
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, expected.rawValue, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: conda install --pack --reinstall

    func testReinstallParsesOnlyWithAPack() throws {
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", "multiple-sequence-alignment", "--reinstall", "--format", "json"])
        XCTAssertTrue(command.reinstall)
        XCTAssertTrue(command.isPack)
        XCTAssertFalse(try CondaCommand.InstallSubcommand.parse(["--pack", "multiple-sequence-alignment"]).reinstall)
        XCTAssertThrowsError(try CondaCommand.InstallSubcommand.parse(["samtools", "--reinstall"]))
        XCTAssertThrowsError(try CondaCommand.InstallSubcommand.parse(
            ["--pack", "x", "--reinstall", "--offline", "--from-bundle", "/tmp/pack"]
        ))
    }

    func testAReinstallRecreatesThePackAndRecordsIt() async throws {
        let pack = try Fixtures.pack()
        let service = Fixtures.PackService(.succeed)
        CondaCommand.packStatusServiceOverride = service
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--reinstall", "--format", "json"])
        let lines = Fixtures.Lines()

        try await command.executePacks(eventsOn: true, quiet: true, emit: lines.append)

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.packID), [pack.id])
        XCTAssertEqual(requests.map(\.reinstall), [true])
        let events = lines.events
        XCTAssertEqual(events.first, .start(message: "Reinstalling \(pack.name)..."))
        guard case .complete(let outputs, let message)? = events.last else { return XCTFail("ends with complete: \(events)") }
        XCTAssertEqual(message, "\(pack.name) reinstalled")
        let record = try XCTUnwrap(outputs.first)
        XCTAssertTrue(record.contains("/provenance/packs/") && record.hasSuffix("-\(pack.id)-reinstall.lungfish-provenance.json"), record)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: URL(fileURLWithPath: record)))
        XCTAssertEqual(envelope.status, .completed)
        XCTAssertEqual(envelope.workflowName, "conda-pack-install")
        XCTAssertEqual(envelope.argv, ["lungfish-cli", "conda", "install", "--pack", pack.id, "--reinstall"])
        XCTAssertEqual(envelope.steps.map(\.toolName), ["first-tool", "second-tool"])
        let fractions = events.compactMap { event -> Double? in
            if case .progress(let fraction, _) = event { return fraction }
            return nil
        }
        XCTAssertEqual(fractions, [0.25, 0.75])
    }

    func testAPlainInstallPassesFalseAndRecordsAnInstall() async throws {
        let pack = try Fixtures.pack()
        let service = Fixtures.PackService(.succeed)
        CondaCommand.packStatusServiceOverride = service
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--format", "json"])
        let lines = Fixtures.Lines()

        try await command.executePacks(eventsOn: true, quiet: true, emit: lines.append)

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.reinstall), [false])
        XCTAssertEqual(lines.events.first, .start(message: "Installing \(pack.name)..."))
        XCTAssertEqual(try Fixtures.recordStatus(storageRoot: root, folder: "packs"), "completed")
    }

    func testAFailedPackRunRecordsFailedAndExitsDependency() async throws {
        let pack = try Fixtures.pack()
        CondaCommand.packStatusServiceOverride = Fixtures.PackService(.fail)
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--reinstall", "--format", "json"])
        let lines = Fixtures.Lines()

        await assertExit(.dependency) { try await command.executePacks(eventsOn: true, quiet: true, emit: lines.append) }

        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertEqual(message, "Tool pack '\(pack.name)' failed verification: second-tool does not run")
        XCTAssertEqual(try Fixtures.recordStatus(storageRoot: root, folder: "packs"), "failed")
    }

    func testSIGTERMCancelsAPackReinstallAndRecordsItCancelled() async throws {
        let pack = try Fixtures.pack()
        let atWork = Fixtures.AtWork()
        CondaCommand.packStatusServiceOverride = Fixtures.PackService(.stall, atWork: atWork)
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--reinstall", "--format", "json"])
        let lines = Fixtures.Lines()
        let previousSIGTERM = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previousSIGTERM) }
        let run = Task { try await command.executePacks(eventsOn: true, quiet: true, emit: lines.append) }

        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) { atWork.isSet }
        XCTAssertTrue(started)
        kill(getpid(), SIGTERM)

        await assertExit(.cancelled) { try await run.value }
        XCTAssertEqual(try Fixtures.recordStatus(storageRoot: root, folder: "packs"), "cancelled")
        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertTrue(message.hasPrefix("Installation cancelled"), message)
    }

    // MARK: tools update --only

    private func plan() -> ReconciliationPlan {
        func change(_ name: String, required: Bool) -> ReconciliationPlan.EnvironmentChange {
            .init(environment: name, packID: "p", currentSpec: nil, targetSpec: "bioconda::\(name)=1=h0", reason: .missing, isRequired: required)
        }
        func database(_ id: String, _ policy: DatabaseUpdatePolicy) -> ReconciliationPlan.DatabaseChange {
            .init(id: id, displayName: id, installedVersion: "1", targetVersion: "2", policy: policy, estimatedBytes: 1, managedBy: .databaseRegistry)
        }
        return ReconciliationPlan(
            installEnvironments: [change("req-a", required: true), change("opt-b", required: false), change("opt-c", required: false)],
            reinstallEnvironments: [],
            removeEnvironments: ["retired-x", "retired-y"],
            databaseUpdates: [database("db-required", .required), database("db-advisory", .advisory)],
            pipelinePrefetch: [], bootstrapUpdate: nil, targetDependencySet: "2026.2", estimatedDownloadBytes: 0
        )
    }

    func testOnlyIsRepeatableAndNeedsApply() throws {
        let command = try ToolsCommand.UpdateSubcommand.parse(["--apply", "--yes", "--only", "opt-b", "--only", "db-advisory"])
        XCTAssertEqual(command.only, ["opt-b", "db-advisory"])
        XCTAssertEqual(try ToolsCommand.UpdateSubcommand.parse(["--apply", "--yes"]).only, [])
    }

    func testOnlyChoosesItemsAndFoldsTheRequiredWorkIn() throws {
        let chosen = try ToolsCommand.UpdateSubcommand.choose(only: ["opt-b", "db-advisory", "retired-y"], from: plan())

        XCTAssertEqual(chosen.selection.environments, ["req-a", "opt-b"])
        XCTAssertEqual(chosen.selection.databases, ["db-required", "db-advisory"])
        XCTAssertTrue(chosen.selection.includeRemovals)
        XCTAssertEqual(chosen.plan.removeEnvironments, ["retired-y"], "only the named retired environment goes")
        XCTAssertEqual(chosen.foldedIn, ["db-required", "req-a"])

        let none = try ToolsCommand.UpdateSubcommand.choose(only: ["opt-c"], from: plan())
        XCTAssertFalse(none.selection.includeRemovals)
        XCTAssertEqual(none.plan.removeEnvironments, [])
    }

    func testOnlyRefusesAnItemThatIsNotInThePlan() {
        XCTAssertThrowsError(try ToolsCommand.UpdateSubcommand.choose(only: ["opt-b", "typo"], from: plan())) { error in
            XCTAssertEqual(
                error as? ToolsCommand.UpdateSubcommand.ChoiceError,
                .notInPlan(ids: ["typo"], held: ["db-advisory", "db-required", "opt-b", "opt-c", "req-a", "retired-x", "retired-y"])
            )
        }
        XCTAssertThrowsError(try ToolsCommand.UpdateSubcommand.choose(only: [" "], from: plan()))
    }

    private func toolsCommand(_ extra: [String] = []) throws -> ToolsCommand.UpdateSubcommand {
        try ToolsCommand.UpdateSubcommand.parse(
            ["--apply", "--yes", "--format", "json", "--storage-root", root.path] + extra
        )
    }

    func testApplyingAChosenItemPrintsEventsAndNamesItsRecord() async throws {
        ToolsCommand.manifestOverride = Fixtures.manifest()
        ToolsCommand.servicesOverride = Fixtures.services(behaviour: .succeed)
        let lines = Fixtures.Lines()

        try await toolsCommand(["--only", "samtools"]).execute(emit: lines.append)

        let events = lines.events
        XCTAssertEqual(events.first, .start(message: "Updating tools to 2026.2..."))
        guard case .complete(let outputs, let message)? = events.last else { return XCTFail("ends with complete: \(events)") }
        XCTAssertEqual(message, "Updated 1 item(s) to 2026.2")
        let record = try XCTUnwrap(outputs.first)
        XCTAssertTrue(record.contains("/provenance/dependencies/"), record)
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: URL(fileURLWithPath: record))?.status, .completed)
        XCTAssertTrue(events.contains(.progress(fraction: 0.5, message: "samtools: Solving samtools")), "\(events)")
    }

    func testAnItemOutsideThePlanIsRefusedWithExit3BeforeAnythingRuns() async throws {
        ToolsCommand.manifestOverride = Fixtures.manifest()
        ToolsCommand.servicesOverride = Fixtures.services(behaviour: .succeed)
        let lines = Fixtures.Lines()

        await assertExit(.inputError) { try await toolsCommand(["--only", "typo"]).execute(emit: lines.append) }

        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertTrue(message.hasPrefix("Not in the plan: typo."), message)
        XCTAssertNil(try Fixtures.recordStatus(storageRoot: root, folder: "dependencies"), "a refusal writes no record")
    }

    func testSIGTERMCancelsAToolsUpdateAndRecordsItCancelled() async throws {
        let atWork = Fixtures.AtWork()
        ToolsCommand.manifestOverride = Fixtures.manifest()
        ToolsCommand.servicesOverride = Fixtures.services(behaviour: .stall, atWork: atWork)
        let lines = Fixtures.Lines()
        let command = try toolsCommand()
        let previousSIGTERM = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previousSIGTERM) }
        let run = Task { try await command.execute(emit: lines.append) }

        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) { atWork.isSet }
        XCTAssertTrue(started)
        kill(getpid(), SIGTERM)

        await assertExit(.cancelled) { try await run.value }
        XCTAssertEqual(try Fixtures.recordStatus(storageRoot: root, folder: "dependencies"), "cancelled")
        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertTrue(message.hasPrefix("Update cancelled"), message)
    }

    // MARK: conda db update

    private func dbCommand(_ extra: [String] = ["--yes"]) throws -> DbCommand.DbUpdateSubcommand {
        try DbCommand.DbUpdateSubcommand.parse(["kraken2-viral", "--format", "json"] + extra)
    }

    func testADatabaseUpdatePrintsEventsAndNamesTheUpdatedFolder() async throws {
        let registry = try await Fixtures.registry(in: root.appendingPathComponent("databases"), stalling: false)
        DbCommand.DbUpdateSubcommand.registryOverride = registry
        let lines = Fixtures.Lines()

        try await dbCommand().execute(eventsOn: true, quiet: true, emit: lines.append)

        let events = lines.events
        XCTAssertEqual(events.first, .start(message: "Updating kraken2-viral..."))
        guard case .complete(let outputs, let message)? = events.last else { return XCTFail("ends with complete: \(events)") }
        XCTAssertEqual(message, "Updated 1 database(s): kraken2-viral")
        let installed = root.appendingPathComponent("databases/kraken2/viral", isDirectory: true)
        XCTAssertEqual(outputs.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, [installed.standardizedFileURL.path])
        XCTAssertEqual(Fixtures.markers(of: installed), ["new", "new", "new"])
        XCTAssertTrue(events.contains(.progress(fraction: 0.425, message: "Downloading Viral")), "\(events)")
    }

    func testADatabaseUpdateWithoutYesIsAFailedEventWithExit2() async throws {
        let lines = Fixtures.Lines()
        await assertExit(.usage) { try await dbCommand([]).execute(eventsOn: true, quiet: true, emit: lines.append) }
        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertTrue(message.contains("re-run with --yes"), message)
    }

    func testSIGTERMCancelsADatabaseUpdateLeavesTheInstalledCopyWholeAndRecordsCancelled() async throws {
        let atWork = Fixtures.AtWork()
        let base = root.appendingPathComponent("databases")
        DbCommand.DbUpdateSubcommand.registryOverride = try await Fixtures.registry(in: base, stalling: true, atWork: atWork)
        let lines = Fixtures.Lines()
        let command = try dbCommand()
        let previousSIGTERM = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previousSIGTERM) }
        let run = Task { try await command.execute(eventsOn: true, quiet: true, emit: lines.append) }

        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) { atWork.isSet }
        XCTAssertTrue(started)
        kill(getpid(), SIGTERM)

        await assertExit(.cancelled) { try await run.value }
        XCTAssertEqual(try Fixtures.recordStatus(storageRoot: root, folder: "databases"), "cancelled")
        let installed = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        XCTAssertEqual(Fixtures.markers(of: installed), ["old", "old", "old"], "the installed database is whole")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("kraken2").path), ["viral"])
        guard case .failed(let message, _)? = lines.events.last else { return XCTFail("ends with failed: \(lines.events)") }
        XCTAssertTrue(message.hasPrefix("Update cancelled"), message)
    }
}
