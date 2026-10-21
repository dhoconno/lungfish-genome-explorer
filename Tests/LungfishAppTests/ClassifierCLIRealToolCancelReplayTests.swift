// ClassifierCLIRealToolCancelReplayTests.swift - The real kraken2 cancelled, and failing, under the classifier CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane S6, the test row at line 430 of docs/plans/2026-10-11-phase-2-7.md. The CLI
// route's cancel and failure paths have stand-in cases (ClassifierCLIRouteRowTests,
// CLIClassifierRunnerTests) and owner check list row 4, and no case that runs the real tool.
// Each case here hands the dialog's launch, `AppDelegate.launchClassification`, the configs of a
// K1 run (classification alone, the balanced preset, one thread, as
// ClassifierCLIGUIParityReplayTests+Sides.swift builds them) with every route key set to the CLI
// route, so `CLIClassifierRunner` runs the built `lungfish-cli`, which runs the real `kraken2` of
// `~/.lungfish-stable`.
//
// - Cancel. K1's own 55 reads end before a cancel can land, so the case classifies a generated
//   plain bundle that keeps kraken2 busy for seconds. It cancels the row once the row shows the
//   first kraken2 progress event and kraken2's `classify` is alive under the command. The row
//   must read Cancelled with no alert. The command must end the run itself inside the transport's
//   grace with the exit status 125 (read from the process, which the transport drops), a
//   `cancelled` run record and root record, a folder that stays hidden, no process of the run
//   left once the grace ends, and no byte written into the project after it exits.
// - Failure. K1's own bundle, and a database registry of its own that names a folder of text
//   files in a Kraken2 database's file names, so kraken2 itself fails on it. The row must read
//   Failed with the log tail of kraken2 in its alert, the command must exit with the workflow
//   error status and leave a `failed` run record and root record, the folder stays hidden, and no
//   byte is written after the command exits.
//
// Real tools run, so the class name ends in ReplayTests, which sends it to the integration tier
// and the replay step and keeps it out of the parallel unit tier. `LUNGFISH_REQUIRE_TOOLS=1` turns
// a missing tool or database into a failure. Every wait ends as soon as its condition holds. Run
// the class once with every core busy (`yes > /dev/null` on each core) as well as alone, since an
// idle machine hides timing faults.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierCLIRealToolCancelReplayTests: XCTestCase {
    /// Reads in the cancel case's input. kraken2 classifies about 50,000 random 150-base reads a
    /// second with one thread and the Viral database on a 20-core Mac, so this keeps it busy for
    /// about twelve seconds, where a cancel takes under one.
    static let cancelReadCount = 600_000

    /// How long a wait may take before the case gives up on it.
    private static let patience: Duration = .seconds(30)

    /// How long the project must stay as it was when the command exited. A wait for something
    /// that must not happen cannot end early.
    private static let quietPeriod: Duration = .seconds(5)

    private struct LaunchedRow {
        let id: UUID
        let window: NSWindow
        let project: URL

        var analyses: URL { project.appendingPathComponent("Analyses", isDirectory: true) }
    }

    private struct CaseFailure: Error {}

    private var scratch: URL!
    private var savedEnvironment: [String: String?] = [:]
    private var registryDigestBefore: String?
    private var rowIDs: [UUID] = []
    private var windows: [NSWindow] = []
    private var delegates: [AppDelegate] = []

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail("No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH.")
            throw ToolAvailabilityError.required("lungfish-cli")
        }
        scratch = try TestTempDirectory.make(prefix: "classifier-real-cancel")
        setEnvironment("LUNGFISH_CLI_PATH", to: cli.path)
        registryDigestBefore = Self.registryDigest()
    }

    override func tearDown() async throws {
        // A case that failed part way leaves its run going, so stop it before its folder goes.
        for id in rowIDs where item(id)?.state == .running {
            OperationCenter.shared.cancel(id: id)
        }
        _ = await waitUntil(timeout: Self.patience) {
            self.rowIDs.allSatisfy { self.item($0).map { !$0.state.isActive } ?? true }
        }
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }
        windows.removeAll()
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        savedEnvironment.removeAll()
        XCTAssertEqual(
            Self.registryDigest(), registryDigestBefore,
            "a case wrote \(ClassifierParityFixtures.stableRegistryURL.path)"
        )
        if let scratch { TestTempDirectory.cleanup(scratch) }
        try await super.tearDown()
    }

    // MARK: - Cancel

    /// A cancel after the first kraken2 progress event, with kraken2 running under the command.
    func testACancelledK1LaunchEndsCancelledWithItsRecordAndWritesNothingAfterTheCommandExits() async throws {
        let viral = try await requireTools(viralDatabase: true)
        let project = scratch.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/cancel-reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.writeRandomReads(to: bundle.appendingPathComponent("cancel-reads.fastq"), count: Self.cancelReadCount)
        let database = try XCTUnwrap(viral)
        let configs = await k1Configs(bundle: bundle, database: database, databasePath: try XCTUnwrap(database.path))
        let run = try launch(configs, project: project)

        let sawProgress = await waitUntil(timeout: Self.patience) {
            self.loggedLines(of: run.id).contains("Running kraken2...")
        }
        try demand(sawProgress, "the row never showed the first kraken2 progress event")
        let scratchName = scratch.lastPathComponent
        let toolRunning = await waitUntil(timeout: Self.patience, pollInterval: .milliseconds(25)) {
            await Self.isKraken2Running(mentioning: scratchName)
        }
        try demand(toolRunning, "kraken2 never ran under the command")
        let command = try await runningCommand(in: run.analyses)
        let watcher = try XCTUnwrap(ChildExitWatcher(pid: command.pid), "the command is gone or no child of this process")

        let cancelRequestedAt = ContinuousClock.now
        OperationCenter.shared.cancel(id: run.id)
        let exitOrNil = await watcher.waitForExit(timeout: 30, snapshotting: project)
        let ended = try XCTUnwrap(exitOrNil, "the command did not exit after the cancel")

        // The whole tool tree goes inside the grace, as the command does. A `classify` left running
        // ends by itself about ten seconds after the cancel, inside the 30 s wait, so the wait alone
        // cannot see it.
        let processesGone = await waitUntil(timeout: Self.patience, pollInterval: .milliseconds(100)) {
            await Self.commandLines(mentioning: scratchName)?.isEmpty == true
        }
        let goneBy = ContinuousClock.now
        XCTAssertTrue(processesGone, "a process of the cancelled run is still alive")
        XCTAssertLessThan(
            goneBy - cancelRequestedAt, CLIClassifierRunner.terminationGracePeriod,
            "a process of the cancelled run outlived the grace"
        )

        let finished = await waitUntil(timeout: Self.patience) { self.item(run.id).map { !$0.state.isActive } ?? true }
        try demand(finished, "the row did not finish after the cancel")

        // The row.
        let item = try XCTUnwrap(self.item(run.id))
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertNil(item.errorMessage)
        XCTAssertNil(run.window.attachedSheet, "a cancel shows no alert")
        XCTAssertFalse(
            loggedLines(of: run.id).contains { $0.contains("did not respond to cancellation") },
            "OperationCenter forced the row, so the command did not end the run itself"
        )

        // The command. It exits 125 by itself inside the grace, not by SIGKILL (a negative code).
        XCTAssertEqual(AnalysisRunExitCode.cancelled, 125)
        XCTAssertEqual(ended.code, 125, "the command's own exit status")
        XCTAssertLessThan(ended.at - cancelRequestedAt, CLIClassifierRunner.terminationGracePeriod, "the command outlasted the grace")
        XCTAssertEqual(AnalysisRunRecord.load(from: command.folder)?.outcome, .cancelled)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: command.folder), "the command wrote no root record")
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.exitStatus, 125)
        try assertHidden(command.folder, in: project)

        await assertNothingWritten(after: ended.project, in: project)
        XCTAssertNil(run.window.attachedSheet, "a cancel shows no alert, also after the quiet period")
        try assertListedOnceItsRecordIsGone(command.folder, in: project)
    }

    // MARK: - Failure

    /// A launch kraken2 fails on, because the registry names a folder that is no database.
    func testAK1LaunchThatKraken2FailsOnEndsFailedWithItsRecordAndTheLogTailInTheAlert() async throws {
        _ = try await requireTools(viralDatabase: false)
        let project = try ClassifierParityFixtures.makeProject(in: scratch)
        let database = try await registerNotAKraken2Database()
        let subset = project.appendingPathComponent(ClassifierParityFixtures.subsetBundlePath, isDirectory: true)
        let configs = await k1Configs(bundle: subset, database: database, databasePath: try XCTUnwrap(database.path))
        let run = try launch(configs, project: project)

        let command = try await runningCommand(in: run.analyses)
        let watcher = try XCTUnwrap(ChildExitWatcher(pid: command.pid), "the command is gone or no child of this process")
        let exitOrNil = await watcher.waitForExit(timeout: 30, snapshotting: project)
        let ended = try XCTUnwrap(exitOrNil, "the command did not exit")
        let finished = await waitUntil(timeout: Self.patience) { self.item(run.id).map { !$0.state.isActive } ?? true }
        try demand(finished, "the row did not finish")
        _ = await waitUntil(timeout: .seconds(5)) { run.window.attachedSheet != nil }

        // The row and its alert hold kraken2's own words, the log tail of the failed tool.
        let item = try XCTUnwrap(self.item(run.id))
        let alert = try XCTUnwrap(run.window.attachedSheet.map(Self.texts(in:)), "a failed run shows an alert")
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertTrue(alert.hasPrefix(AppDelegate.classificationFailedAlertTitle + "\n"), alert)
        XCTAssertTrue(alert.contains("kraken2 failed with exit code"), alert)
        XCTAssertTrue(alert.contains("malformed taxonomy file"), "the alert holds the log tail of kraken2: \(alert)")
        XCTAssertTrue(alert.contains("taxo.k2d"), alert)
        XCTAssertTrue(item.detail.contains("malformed taxonomy file"), item.detail)
        let report = try XCTUnwrap(item.failureReportURL, "a failed row writes its failure report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))

        // The command's own records, and its exit.
        XCTAssertEqual(ended.code, AnalysisRunExitCode.workflowError, "the command's own exit status")
        XCTAssertEqual(AnalysisRunRecord.load(from: command.folder)?.outcome, .failed)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: command.folder), "the command wrote no root record")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.exitStatus, Int(AnalysisRunExitCode.workflowError))
        XCTAssertTrue(record.stderr?.contains("malformed taxonomy file") == true, record.stderr ?? "no stderr")
        try assertHidden(command.folder, in: project)
        await assertNothingWritten(after: ended.project, in: project)
        try assertListedOnceItsRecordIsGone(command.folder, in: project)
    }

    // MARK: - Launch

    /// The tools a case runs, through `ToolAvailability`, so `LUNGFISH_REQUIRE_TOOLS=1` fails
    /// instead of skipping. Returns the Stable Viral database when the case runs it.
    private func requireTools(viralDatabase: Bool) async throws -> MetagenomicsDatabaseInfo? {
        _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        _ = try await ToolAvailability.require("kraken2", environment: "kraken2")
        guard viralDatabase else { return nil }
        let viral = try await MetagenomicsDatabaseRegistry.shared.database(named: "Viral")
        _ = try await Self.requireDatabase(at: viral?.path, name: "Kraken2 Viral in the Stable registry")
        return viral
    }

    /// `ToolAvailability.requireDatabase` for a location already resolved, called outside the
    /// main actor so its resolver closure stays in one isolation domain.
    nonisolated private static func requireDatabase(at url: URL?, name: String) async throws -> URL {
        try await ToolAvailability.requireDatabase({ url }, name: name)
    }

    /// The configs the classification wizard builds for `bundle` in the shape of the parity case
    /// K1: the `.classify` goal with no Bracken request, the balanced preset and one thread.
    private func k1Configs(
        bundle: URL,
        database: MetagenomicsDatabaseInfo,
        databasePath: URL
    ) async -> [ClassificationConfig] {
        let preset = ClassificationConfig.Preset.balanced.parameters
        var configs: [ClassificationConfig] = []
        for sample in MetagenomicsSampleGrouper.group([bundle]) {
            let plan = await ClassificationSampleReadPlan.planned(for: sample)
            var config = ClassificationConfig(
                goal: .classify,
                inputFiles: sample.inputFiles,
                isPairedEnd: plan.format == .paired,
                interleavedInput: plan.format == .interleaved,
                inputLayout: plan.layout,
                databaseName: database.name,
                databaseVersion: database.version ?? "unknown",
                databasePath: databasePath,
                databaseDigest: database.payloadDigest,
                databaseCatalogID: database.catalogID,
                databaseInstallationRecipe: database.installationRecipe,
                brackenProfileRequest: nil,
                confidence: preset.confidence,
                minimumHitGroups: preset.minimumHitGroups,
                threads: 1,
                memoryMapping: false,
                quickMode: false,
                outputDirectory: bundle.deletingLastPathComponent().appendingPathComponent("classification-0000S6C1"),
                extraArguments: []
            )
            config.plansReadSet = plan.plansReadSet
            configs.append(config)
        }
        return configs
    }

    /// Hands `configs` to the dialog's launch, as side C of the parity cases does, in a window that
    /// is never ordered front and holds a failed run's alert.
    private func launch(_ configs: [ClassificationConfig], project: URL) throws -> LaunchedRow {
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        delegates.append(delegate)
        windows.append(window)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        delegate.launchClassification(
            configs: configs,
            viewerController: viewer,
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        )
        let started = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }, "the launch started no row")
        rowIDs.append(started.id)
        return LaunchedRow(id: started.id, window: window, project: project)
    }

    /// A database registry of its own, in a storage root of its own, with one entry, `NotKraken2`,
    /// a folder of three text files in the file names of a Kraken2 database. The command resolves
    /// `--db` by registry name, so the registry is how a launch reaches a database a test made. The
    /// launch passes the process environment to the command, so the command reads this registry
    /// while it still finds the tools in the Stable conda root. The Stable registry is not touched.
    private func registerNotAKraken2Database() async throws -> MetagenomicsDatabaseInfo {
        let folder = scratch.appendingPathComponent("not-a-kraken2-database", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "This is not a Kraken2 database.\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let storage = scratch.appendingPathComponent("storage", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: storage.appendingPathComponent("databases", isDirectory: true))
        let database = try await registry.seedRowThroughManifest(at: folder, name: "NotKraken2")
        setEnvironment("LUNGFISH_CONDA_ROOT", to: ManagedStorageConfigStore().currentCondaRootURL().path)
        setEnvironment("LUNGFISH_STORAGE_ROOT", to: storage.path)
        return database
    }

    // MARK: - The command

    /// The folder the command made under `analyses` and the process that owns it, from its run
    /// record, which exists as soon as the folder does.
    private func runningCommand(in analyses: URL) async throws -> (folder: URL, pid: Int32) {
        var found: (folder: URL, pid: Int32)?
        let appeared = await waitUntil(timeout: Self.patience, pollInterval: .milliseconds(2)) {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: analyses,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let folder = folders.first, let pid = AnalysisRunRecord.load(from: folder)?.processIdentifier else {
                return false
            }
            found = (folder, pid)
            return true
        }
        try demand(appeared, "the command made no folder with a run record in \(analyses.path)")
        return try XCTUnwrap(found)
    }

    /// The folder is a run that did not complete: it keeps its record, so no listing shows it.
    private func assertHidden(_ folder: URL, in project: URL) throws {
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(folder), "the folder lost its run record")
        let listed = try AnalysesFolder.listAnalyses(in: project).map { $0.url.lastPathComponent }
        XCTAssertFalse(listed.contains(folder.lastPathComponent), "\(listed) lists the run")
    }

    /// Hidden has to mean the record hides it: once the record is gone the same folder is listed.
    /// This runs last, since it writes into the project.
    private func assertListedOnceItsRecordIsGone(_ folder: URL, in project: URL) throws {
        AnalysisRunRecord.markComplete(folder)
        let listed = try AnalysesFolder.listAnalyses(in: project).map { $0.url.lastPathComponent }
        XCTAssertTrue(listed.contains(folder.lastPathComponent), "\(listed) does not list the run without its record")
    }

    /// E5. The route settles nothing itself: `projectAtExit` is the project the moment the command
    /// was gone, and it must still be the project when the row finished and for the quiet period
    /// after, bytes, modification times and file numbers, which an atomic rewrite changes.
    private func assertNothingWritten(after projectAtExit: [String: String], in project: URL) async {
        XCTAssertEqual(
            Self.fileStates(under: project), projectAtExit,
            "the route wrote into the project between the command's exit and the end of the row"
        )
        let changed = await waitUntil(timeout: Self.quietPeriod, pollInterval: .milliseconds(100)) {
            Self.fileStates(under: project) != projectAtExit
        }
        XCTAssertFalse(changed, "the route wrote into the project after the row finished")
    }

    // MARK: - Helpers

    private func demand(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw CaseFailure()
        }
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func loggedLines(of id: UUID) -> [String] {
        item(id)?.logEntries.filter { !$0.isElisionMarker }.map(\.message) ?? []
    }

    /// Sets an environment variable of the process for the case and puts it back afterwards.
    private func setEnvironment(_ key: String, to value: String) {
        if savedEnvironment[key] == nil {
            savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key])
        }
        setenv(key, value, 1)
    }

    private static func registryDigest() -> String? {
        let registry = ClassifierParityFixtures.stableRegistryURL
        guard FileManager.default.fileExists(atPath: registry.path) else { return nil }
        return try? ClassifierParityFixtures.sha256(of: registry)
    }

    /// The text fields of a sheet, top to bottom, one per line.
    private static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }

    // MARK: - The process table and the file system

    /// The command line of every process whose command line names `token`, from `ps`, read off
    /// the main actor. Nil when `ps` failed, so a check that wants no process fails closed.
    @concurrent
    private static func commandLines(mentioning token: String) async -> [String]? {
        guard let listing = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "command="], timeout: 20),
              listing.status == 0 else {
            return nil
        }
        return listing.stdout.split(separator: "\n").map(String.init).filter { $0.contains(token) }
    }

    /// Whether kraken2's own `classify` program is running on this case's files. The command
    /// names the case's folder too, so it is told apart by its program.
    @concurrent
    private static func isKraken2Running(mentioning token: String) async -> Bool {
        (await commandLines(mentioning: token) ?? []).contains { line in
            let program = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return (program as NSString).lastPathComponent == "classify"
        }
    }

    /// The size, modification time and file number of every regular file under `folder`.
    nonisolated fileprivate static func fileStates(under folder: URL) -> [String: String] {
        var states: [String: String] = [:]
        let base = folder.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return states }
        while let url = enumerator.nextObject() as? URL {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let number = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1
            states[relative] = "\(size) bytes, modified \(modified), file \(number)"
        }
        return states
    }

    // MARK: - The input

    /// Writes `count` FASTQ reads of 150 random bases to `url`, from a fixed seed, 4 MiB at a time.
    /// Each read takes its bases from a pool of 16 million random bases at an offset of its own
    /// (the debug build this runs in makes a loop over every base of every read cost seconds).
    /// Random bases classify as nothing, and each still costs kraken2 a hash lookup for every
    /// minimizer, so its time grows with the count.
    private static func writeRandomReads(to url: URL, count: Int) throws {
        let length = 150
        let poolLength = 1 << 24
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextWord() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        // Each byte of random bits becomes four bases, two bits for each of A, C, G and T.
        let letters = Array("ACGT".utf8)
        let basesOfByte: [UInt32] = (0..<256).map { byte in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(letters[(byte >> (2 * $1)) & 3]) << UInt32(8 * $1) }
        }
        var pool = [UInt8](repeating: 0, count: poolLength)
        pool.withUnsafeMutableBytes { bytes in
            for block in 0..<(poolLength / 32) {
                var word = nextWord()
                for part in 0..<8 {
                    bytes.storeBytes(of: basesOfByte[Int(word & 0xFF)], toByteOffset: block * 32 + part * 4, as: UInt32.self)
                    word >>= 8
                }
            }
        }

        let quality = [UInt8](repeating: UInt8(ascii: "I"), count: length)
        var header = Array("@read00000000\n".utf8)
        var chunk: [UInt8] = []
        chunk.reserveCapacity(5 << 20)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for index in 0..<count {
            var number = index
            for position in stride(from: 12, through: 5, by: -1) {
                header[position] = UInt8(ascii: "0") + UInt8(number % 10)
                number /= 10
            }
            let start = Int(nextWord() % UInt64(poolLength - length))
            chunk += header
            chunk += pool[start..<start + length]
            chunk += [0x0A, 0x2B, 0x0A]
            chunk += quality
            chunk.append(0x0A)
            if chunk.count >= 4 << 20 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
    }
}

/// Watches one child process of the test for its exit and reads its wait status. The transport
/// drops the exit of a command it cancelled, so the case watches the command itself.
/// `NOTE_EXITSTATUS` gives a parent the status of its child, and the app launches the command
/// from this process. The watch is in place when the initializer returns, so an exit cannot come
/// before it.
private final class ChildExitWatcher: Sendable {
    /// How the command ended, and the project the instant it had.
    struct Exit: Sendable {
        /// The exit code, or minus the number of the signal that ended the process.
        let code: Int32
        let project: [String: String]
        let at: ContinuousClock.Instant
    }

    private let queue: Int32

    /// Nil when `pid` is gone already or is no child of this process.
    init?(pid: Int32) {
        let queue = kqueue()
        guard queue >= 0 else { return nil }
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            return nil
        }
        self.queue = queue
    }

    deinit {
        close(queue)
    }

    /// Waits up to `timeout` seconds, off the main actor, for the process to exit. The files of
    /// `project` are read as soon as the kernel reports the exit. The app learns of the exit through
    /// its own transport at the same time, so this is early but not ordered before the app.
    @concurrent
    func waitForExit(timeout: Int, snapshotting project: URL) async -> Exit? {
        var event = kevent()
        var limit = timespec(tv_sec: timeout, tv_nsec: 0)
        guard kevent(queue, nil, 0, &event, 1, &limit) == 1, event.fflags & UInt32(NOTE_EXIT) != 0 else {
            return nil
        }
        let files = ClassifierCLIRealToolCancelReplayTests.fileStates(under: project)
        let status = Int32(truncatingIfNeeded: event.data)
        return Exit(
            code: status & 0x7F == 0 ? (status >> 8) & 0xFF : -(status & 0x7F),
            project: files,
            at: ContinuousClock.now
        )
    }
}
