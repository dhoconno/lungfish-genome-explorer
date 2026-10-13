// ClassifierCLIRouteSidebarTests.swift - What the classifier CLI route asks of the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A32 with U39. The route ends a run in `finishClassifierThroughCLI` and
// `failClassifierThroughCLI` (AppDelegate+ClassificationCLIRoute.swift), which ask the sidebar of the
// window that owns the project for a reveal or a reload, and no other test watched the sidebar.
// Each test runs the route through `AppDelegate.runClassificationThroughCLI` or
// `runEsVirituThroughCLI` with a stand-in `lungfish-cli` that plays what the real executor printed
// (ClassifierCLIRouteFixtures.swift), in a real main window whose sidebar shows the project. The
// sidebar is the real one. The test replaces its selection delegate with a recorder, counts its
// scans through the DEBUG scan hook, and drops its file watcher, so only a request of the route, or
// the Operations Panel's own notice that a result finished, can make it scan.
//
// What tells the asks apart. A reveal (`reloadAndRevealItem`) selects the result's row without
// telling the delegate, since the viewport already shows the result. A reload
// (`requestReloadFromFilesystem`) tells the delegate that the selected row refreshed. The Operations
// Panel's notice for a finished result reloads without that refresh, and a failed run sends no notice.
// So a row selected before the run, and the refresh the recorder sees, show that the route asked.

import AppKit
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierCLIRouteSidebarTests: XCTestCase {
    private var root: URL!
    private var scans = SidebarScanCounter()
    private var rowsBefore: Set<UUID> = []
    private var savedBundleReady: (([URL], OperationRouteContext?) -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "classifier-cli-route-sidebar")
        OperationCenter.useTemporaryFailureReportsForTesting()
        rowsBefore = Set(OperationCenter.shared.items.map(\.id))
        savedBundleReady = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { _, _ in }
        let counter = SidebarScanCounter()
        scans = counter
        SidebarViewController.scanBarrierForTesting = { counter.record() }
    }

    override func tearDown() async throws {
        SidebarViewController.scanBarrierForTesting = nil
        OperationCenter.shared.onBundleReadyWithContext = savedBundleReady
        for item in OperationCenter.shared.items where !rowsBefore.contains(item.id) {
            OperationCenter.shared.clearItem(id: item.id)
        }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Completed

    /// A single Kraken2 run reveals its result folder. The viewport already shows the result, so
    /// the sidebar selects the row and never opens it again (AppDelegate+ClassificationCLIRoute.swift:346).
    func testASingleKraken2RunRevealsItsResultFolderWithoutOpeningItAgain() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000A32A")]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder),
            made: made
        )

        let revealed = await waitUntil(timeout: .seconds(30)) { run.selectedPaths == [run.folderPath] }
        XCTAssertTrue(revealed, "the sidebar never selected the result folder, it selects \(run.selectedPaths)")
        XCTAssertTrue(run.rowPaths.contains(run.folderPath), "the finished result is a row")
        XCTAssertEqual(run.recorder.selections, [], "the reveal must not open the result again")
        XCTAssertEqual(run.recorder.refreshes, [], "the reveal asks no refresh of the selected row")
        XCTAssertGreaterThanOrEqual(scans.count, 1)
    }

    /// A Kraken2 batch reloads the sidebar and has the selected row refreshed. It selects nothing
    /// (AppDelegate+ClassificationCLIRoute.swift:352).
    func testAKraken2BatchReloadsTheSidebarAndSelectsNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let run = try await runThroughRoute(
            .kraken2([
                kraken2Config(inputs: [made.inputs[0]], sampleFolder: "classification-batch-x/A"),
                kraken2Config(inputs: [made.inputs[1]], sampleFolder: "classification-batch-x/B"),
            ]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("A", .complete), ("B", .complete)], layout: .batchRoot),
            made: made
        )

        try await expectAReloadWithTheResultShown(run)
    }

    /// An EsViritu run of one sample reloads the sidebar and selects nothing, since the user picks
    /// the new result there (AppDelegate+ClassificationCLIRoute.swift:355).
    func testAnEsVirituRunReloadsTheSidebarAndSelectsNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .esViritu([esVirituConfig(sample: "air-A", inputs: made.inputs)]),
            tool: StandInClassifierTool(tool: .esViritu, units: [("air-A", .complete)], layout: .batchRoot),
            made: made
        )

        try await expectAReloadWithTheResultShown(run)
    }

    /// An EsViritu batch takes the same case as a run of one sample (AppDelegate+ClassificationCLIRoute.swift:353).
    func testAnEsVirituBatchReloadsTheSidebarAndSelectsNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let run = try await runThroughRoute(
            .esViritu([
                esVirituConfig(sample: "A", inputs: [made.inputs[0]]),
                esVirituConfig(sample: "B", inputs: [made.inputs[1]]),
            ]),
            tool: StandInClassifierTool(tool: .esViritu, units: [("A", .complete), ("B", .complete)], layout: .batchRoot),
            made: made
        )

        try await expectAReloadWithTheResultShown(run)
    }

    // MARK: - Failed

    /// A failed Kraken2 batch reloads the sidebar, since samples may have left results, and has the
    /// selected row refreshed. The failed folder stays out of the sidebar
    /// (AppDelegate+ClassificationCLIRoute.swift:399 to 402).
    func testAFailedKraken2BatchReloadsTheSidebarAndKeepsItsFolderOut() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let run = try await runThroughRoute(
            .kraken2([
                kraken2Config(inputs: [made.inputs[0]], sampleFolder: "classification-batch-x/A"),
                kraken2Config(inputs: [made.inputs[1]], sampleFolder: "classification-batch-x/B"),
            ]),
            tool: StandInClassifierTool(
                tool: .kraken2,
                units: [("A", .fail("Empty Kraken2 report", logTail: nil)), ("B", .fail("kraken2 exited with status 2", logTail: nil))],
                layout: .batchRoot
            ),
            made: made,
            expectsAlert: true
        )

        let refreshed = await waitUntil(timeout: .seconds(30)) { !run.recorder.refreshes.isEmpty }
        XCTAssertTrue(refreshed, "the failed batch never asked the sidebar to reload")
        XCTAssertEqual(run.item.displayStateLabel, "Failed")
        XCTAssertEqual(run.recorder.refreshes, [[run.importsPath]], "the reload has the selected row refreshed")
        XCTAssertEqual(run.recorder.selections, [])
        XCTAssertEqual(run.selectedPaths, [run.importsPath], "a failed run reveals nothing")
        XCTAssertFalse(run.rowPaths.contains(run.folderPath), "a failed run's folder stays out of the sidebar")
        XCTAssertGreaterThanOrEqual(scans.count, 1)
    }

    /// A failed single Kraken2 run asks nothing of the sidebar. The alert is all the user gets.
    func testAFailedSingleKraken2RunAsksNothingOfTheSidebar() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000A32B")]),
            tool: StandInClassifierTool(
                tool: .kraken2,
                units: [("reads", .fail("kraken2 exited with status 2", logTail: nil))],
                layout: .singleFolder
            ),
            made: made,
            expectsAlert: true
        )

        try await expectNothingAsked(of: run)
    }

    /// A failed EsViritu run asks nothing either.
    func testAFailedEsVirituRunAsksNothingOfTheSidebar() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .esViritu([esVirituConfig(sample: "air-A", inputs: made.inputs)]),
            tool: StandInClassifierTool(
                tool: .esViritu,
                units: [("air-A", .fail("EsViritu exited with status 1", logTail: "line 1"))],
                layout: .batchRoot
            ),
            made: made,
            expectsAlert: true
        )

        try await expectNothingAsked(of: run)
    }

    // MARK: - Expectations

    /// A finished run that reveals nothing. The sidebar scanned again, shows the result as a row,
    /// keeps the row selected before the run and has it refreshed once.
    private func expectAReloadWithTheResultShown(_ run: Run) async throws {
        let refreshed = await waitUntil(timeout: .seconds(30)) { !run.recorder.refreshes.isEmpty }
        XCTAssertTrue(refreshed, "the run never asked the sidebar to reload")
        let shown = await waitUntil(timeout: .seconds(30)) { run.rowPaths.contains(run.folderPath) }
        XCTAssertTrue(shown, "the finished result never became a row")
        XCTAssertEqual(run.item.displayStateLabel, "Completed")
        XCTAssertEqual(run.recorder.refreshes, [[run.importsPath]], "the reload has the selected row refreshed")
        XCTAssertEqual(run.recorder.selections, [], "nothing opens")
        XCTAssertEqual(run.selectedPaths, [run.importsPath], "the user picks the new result, nothing is revealed")
        XCTAssertGreaterThanOrEqual(scans.count, 1)
    }

    /// A failed run that did not ask for a reload or a reveal. The alert shows, the quiet period
    /// is four times the sidebar's debounce, and no scan, refresh or selection followed.
    private func expectNothingAsked(of run: Run) async throws {
        XCTAssertEqual(run.item.displayStateLabel, "Failed")
        XCTAssertNotNil(run.rig.window.attachedSheet, "the failure's alert shows")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scans.count, 0, "the failed run asked the sidebar to scan")
        XCTAssertEqual(run.recorder.refreshes, [])
        XCTAssertEqual(run.recorder.selections, [])
        XCTAssertEqual(run.selectedPaths, [run.importsPath])
        XCTAssertFalse(run.rowPaths.contains(run.folderPath), "a failed run's folder stays out of the sidebar")
    }
}

// MARK: - One run through the route

private extension ClassifierCLIRouteSidebarTests {
    /// Runs `configs` through the route in a real main window that shows the project, with a
    /// stand-in command that plays what the real executor printed for `tool`. The sidebar has the
    /// project's Imports folder selected before the run, and its recorder and scan count start
    /// empty when the command is let go of. The returned run holds the finished row.
    func runThroughRoute(
        _ configs: RouteConfigs,
        tool: StandInClassifierTool,
        made: (project: URL, inputs: [URL]),
        expectsAlert: Bool = false
    ) async throws -> Run {
        let imports = made.project.appendingPathComponent("Imports", isDirectory: true)
        let launch = try Self.launch(of: configs, project: made.project)
        let rig = makeRig(project: made.project, selecting: imports)

        let recordCopy = root.appendingPathComponent("run-record-\(UUID().uuidString).json")
        var tool = tool
        tool.runRecordCopy = recordCopy
        let transcript = await ClassifierRouteFixtures.transcript(of: tool, project: made.project, inputs: made.inputs, arguments: launch.arguments)
        let folder = try XCTUnwrap(transcript.report.analysisDirectory)
        let completed = transcript.report.status == .completed
        let recordURL = AnalysisRunRecord.url(in: folder)
        if completed {
            // The folder as it is while the command runs. The stand-in settles it at its end.
            try FileManager.default.copyItem(at: recordCopy, to: recordURL)
        }
        let go = root.appendingPathComponent("go-\(UUID().uuidString)")
        let cli = try ClassifierRouteFixtures.standInCLI(
            in: root,
            lines: transcript.lines,
            exitStatus: transcript.report.exitCode,
            holdingTheLastLineUntil: go,
            settling: completed ? recordURL : nil
        )
        let routeContext = rig.delegate.currentOperationRouteContext(for: rig.controller)
        XCTAssertEqual(routeContext?.projectURL?.standardizedFileURL.path, made.project.standardizedFileURL.path)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        switch configs {
        case .kraken2(let configs):
            rig.delegate.runClassificationThroughCLI(configs: configs, viewerController: rig.viewer, routeContext: routeContext, cliURLOverride: cli)
        case .esViritu(let configs):
            rig.delegate.runEsVirituThroughCLI(configs: configs, viewerController: rig.viewer, routeContext: routeContext, cliURLOverride: cli)
        }
        let started = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }, "the route started no row")
        let tracking = await waitUntil(timeout: .seconds(30)) { OperationCenter.shared.isTrackingAnalysisOutput(folder) }
        XCTAssertTrue(tracking, "the row never tracked the folder the output line named")

        // The command still runs, so the folder is hidden and a scan shows no row for it (UX 4).
        rig.sidebar.reloadFromFilesystem()
        XCTAssertFalse(sidebarRowPaths(of: rig.sidebar).contains(folder.standardizedFileURL.path), "a running result must not be a row")
        rig.recorder.reset()
        scans.reset()
        FileManager.default.createFile(atPath: go.path, contents: nil)

        let finished = await waitUntil(timeout: .seconds(30)) { self.item(started.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the row did not finish")
        if expectsAlert {
            _ = await waitUntil(timeout: .seconds(5)) { rig.window.attachedSheet != nil }
        }
        let item = try XCTUnwrap(self.item(started.id))
        return Run(rig: rig, folder: folder, imports: imports, item: item)
    }

    /// A real main window that owns `project` in the app delegate, with a viewer in a window that
    /// is never ordered front, whose sheet holds a failed run's alert. The window's sidebar is the
    /// real one with its file watcher dropped and its selection delegate replaced by a recorder.
    func makeRig(project: URL, selecting selected: URL) -> Rig {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        let sidebar: SidebarViewController = controller.mainSplitViewController.sidebarController
        let recorder = RecordingSidebarDelegate()
        sidebar.selectionDelegate = recorder
        sidebar.openProject(at: project)
        sidebar.detachFilesystemWatcherForTesting()
        XCTAssertTrue(sidebar.selectItem(forURL: selected), "the project's Imports folder is a row")
        recorder.reset()

        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in
            sidebar.closeProject()
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }
        return Rig(delegate: delegate, controller: controller, sidebar: sidebar, recorder: recorder, viewer: viewer, window: window)
    }

    func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    static func launch(of configs: RouteConfigs, project: URL) throws -> ClassifierCLIRouteLaunch {
        switch configs {
        case .kraken2(let configs): return try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: project))
        case .esViritu(let configs): return try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: configs, projectURL: project))
        }
    }

    func kraken2Config(inputs: [URL], sampleFolder: String) -> ClassificationConfig {
        ClassificationConfig(
            goal: .profile,
            inputFiles: inputs,
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: root.appendingPathComponent("Databases/Viral"),
            brackenProfileRequest: .automaticDefault,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 1,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: inputs[0].deletingLastPathComponent().appendingPathComponent(sampleFolder),
            extraArguments: []
        )
    }

    func esVirituConfig(sample: String, inputs: [URL]) -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: inputs,
            isPairedEnd: false,
            sampleName: sample,
            outputDirectory: inputs[0].deletingLastPathComponent().appendingPathComponent("esviritu-x/\(sample)"),
            databasePath: root.appendingPathComponent("Databases/esviritu"),
            qualityFilter: true,
            threads: 1,
            extraArguments: [],
            readFormat: .unpaired,
            inputLayout: nil
        )
    }
}

/// The paths of every row the sidebar shows, standardized.
@MainActor
private func sidebarRowPaths(of sidebar: SidebarViewController) -> Set<String> {
    var paths: Set<String> = []
    func walk(_ items: [SidebarItem]) {
        for item in items {
            if let url = item.url { paths.insert(url.standardizedFileURL.path) }
            walk(item.children)
        }
    }
    walk(sidebar.rootItems)
    return paths
}

private enum RouteConfigs {
    case kraken2([ClassificationConfig])
    case esViritu([EsVirituConfig])
}

/// A main window with its project's sidebar, as the route finds it, and the viewer it is given.
@MainActor
private struct Rig {
    let delegate: AppDelegate
    let controller: MainWindowController
    let sidebar: SidebarViewController
    let recorder: RecordingSidebarDelegate
    let viewer: ViewerViewController
    let window: NSWindow
}

/// One finished run. The paths are read from the live sidebar each time.
@MainActor
private struct Run {
    let rig: Rig
    let folder: URL
    let imports: URL
    let item: OperationCenter.Item

    var recorder: RecordingSidebarDelegate { rig.recorder }
    var folderPath: String { folder.standardizedFileURL.path }
    var importsPath: String { imports.standardizedFileURL.path }
    var selectedPaths: [String] { rig.sidebar.selectedFileURLs().map { $0.standardizedFileURL.path } }
    var rowPaths: Set<String> { sidebarRowPaths(of: rig.sidebar) }
}

/// What the sidebar told its selection delegate, as standardized paths. A selection call is a row
/// the user or a reload selected with callbacks on, and a refresh is a reload that kept the same
/// selection and asked the delegate to refresh it.
@MainActor
private final class RecordingSidebarDelegate: SidebarSelectionDelegate {
    private(set) var selections: [[String]] = []
    private(set) var refreshes: [[String]] = []

    func reset() {
        selections = []
        refreshes = []
    }

    func sidebarDidSelectItem(_ item: SidebarItem?) {
        selections.append(item?.url.map { [$0.standardizedFileURL.path] } ?? [])
    }

    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        selections.append(items.compactMap { $0.url?.standardizedFileURL.path })
    }

    func sidebarDidRefreshSelectedItems(_ items: [SidebarItem]) {
        refreshes.append(items.compactMap { $0.url?.standardizedFileURL.path })
    }
}

/// The scans the sidebar finished, counted by the DEBUG scan hook, which runs off the main actor.
private final class SidebarScanCounter: Sendable {
    private let stored = Mutex(0)

    func record() {
        stored.withLock { $0 += 1 }
    }

    func reset() {
        stored.withLock { $0 = 0 }
    }

    var count: Int {
        stored.withLock { $0 }
    }
}
