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
    /// The result views save their column layouts to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?
    private var scans = SidebarScanCounter()
    private var rowsBefore: Set<UUID> = []
    private var savedBundleReady: (([URL], OperationRouteContext?) -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "classifier-cli-route-sidebar")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
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
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Completed

    /// A single Kraken2 run reveals its result folder. The viewport already shows the result, so
    /// the sidebar selects the row and never opens it again (the single Kraken2 case of `finishClassifierThroughCLI`).
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

    /// A single Kraken2 run points the Inspector at its result (U-INSP-REVEAL, Phase 2.11 lane U61).
    /// The reveal selected the row with callbacks suppressed, so `committedSelectionItems` kept the item
    /// selected before the run and no `.sidebarSelectionChanged` was posted. The Inspector went on showing
    /// that item, such as the input FASTQ's summary and its import record. Once the reveal ends, the sidebar
    /// has posted exactly one notice naming the result, the selection delegate heard nothing, the Inspector's
    /// provenance target is the result, its Summary describes the result and not the details planted before
    /// the run, and nothing was written into the result folder (UX 6).
    func testASingleKraken2RunPointsTheInspectorAtItsResult() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let notices = SelectionNoticeRecorder()
        defer { notices.stop() }
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000U61A")]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder),
            made: made,
            beforeRelease: { rig in
                notices.watch(rig.sidebar)
                Self.plantStaleOperationDetails(in: rig)
            }
        )
        let folderBefore = try TreeDigest.of(run.folder)

        let revealed = await waitUntil(timeout: .seconds(30)) { run.selectedPaths == [run.folderPath] }
        XCTAssertTrue(revealed, "the sidebar never selected the result folder, it selects \(run.selectedPaths)")
        XCTAssertEqual(notices.paths, [run.folderPath], "the reveal posts one selection notice and it names the result")
        XCTAssertEqual(run.recorder.selections, [], "the reveal must not open the result again")

        let inspector = try XCTUnwrap(run.rig.controller.mainSplitViewController.inspectorController)
        XCTAssertEqual(
            inspector.viewModel.provenanceSectionViewModel.currentItem?.url?.standardizedFileURL.path, run.folderPath,
            "the Inspector's provenance target is the result and not the item selected before the run"
        )
        XCTAssertEqual(inspector.viewModel.selectedItem, run.rig.sidebar.selectedItems().first?.title)
        let summary = inspector.viewModel.documentSectionViewModel
        let details = try XCTUnwrap(MainSplitViewController.singleKraken2ResultInspectorDetails(resultURL: run.folder))
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the Summary describes the result, not the planted details")
        XCTAssertEqual(summary.batchOperationParameters, details.parameters)
        XCTAssertEqual(summary.batchSourceSampleURLs.map(\.sampleId), details.sourceSamples.map(\.sampleId))
        XCTAssertEqual(try TreeDigest.of(run.folder), folderBefore, "the reveal and the notice write nothing into the result")
    }

    /// A result with no details to show clears the Summary's Operation Details instead of leaving those of
    /// the result shown before (the clear branch of `showKraken2OperationDetails`).
    func testAResultWithNoDetailsClearsTheOperationDetailsShownBefore() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.updateBatchOperationDetails(tool: "TaxTriage", parameters: ["Stale": "yes"], timestamp: nil, sourceSamples: [])

        AppDelegate.showKraken2OperationDetails(ofResultAt: root, in: inspector)

        let summary = inspector.viewModel.documentSectionViewModel
        XCTAssertNil(summary.batchOperationTool)
        XCTAssertEqual(summary.batchOperationParameters, [:])
        XCTAssertTrue(summary.batchSourceSampleURLs.isEmpty)
    }

    /// A Kraken2 batch reloads the sidebar and has the selected row refreshed. It selects nothing
    /// (the Kraken2 batch case of `finishClassifierThroughCLI`).
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

    /// A Kraken2 batch shows its first sample in the viewport, so the Summary's Operation Details describe that
    /// sample's result and not those of the result shown before (U-INSP-REVEAL, the batch arm of lane U61).
    /// The sidebar still reloads and selects nothing.
    func testAKraken2BatchPointsTheOperationDetailsAtTheSampleItShows() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let run = try await runThroughRoute(
            .kraken2([
                kraken2Config(inputs: [made.inputs[0]], sampleFolder: "classification-batch-u61/A"),
                kraken2Config(inputs: [made.inputs[1]], sampleFolder: "classification-batch-u61/B"),
            ]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("A", .complete), ("B", .complete)], layout: .batchRoot),
            made: made,
            beforeRelease: { rig in Self.plantStaleOperationDetails(in: rig) }
        )

        try await expectAReloadWithTheResultShown(run)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: run.folder))
        let firstSample = run.folder.appendingPathComponent(try XCTUnwrap(manifest.samples.first).resultDirectory, isDirectory: true)
        let details = try XCTUnwrap(MainSplitViewController.singleKraken2ResultInspectorDetails(resultURL: firstSample))
        let summary = run.rig.controller.mainSplitViewController.inspectorController.viewModel.documentSectionViewModel
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the Summary describes the sample the viewport shows")
        XCTAssertEqual(summary.batchOperationParameters, details.parameters)
        XCTAssertEqual(summary.batchSourceSampleURLs.map(\.sampleId), details.sourceSamples.map(\.sampleId))
    }

    /// An EsViritu run of one sample reloads the sidebar and selects nothing, since the user picks
    /// the new result there (the EsViritu case of `finishClassifierThroughCLI`).
    func testAnEsVirituRunReloadsTheSidebarAndSelectsNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .esViritu([esVirituConfig(sample: "air-A", inputs: made.inputs)]),
            tool: StandInClassifierTool(tool: .esViritu, units: [("air-A", .complete)], layout: .batchRoot),
            made: made
        )

        try await expectAReloadWithTheResultShown(run)
    }

    /// An EsViritu batch takes the same case as a run of one sample (`finishClassifierThroughCLI`).
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

    /// A TaxTriage run through the `cli` value reloads the sidebar, has the selected row refreshed and selects
    /// nothing, as an EsViritu run does, because the end of the route shares one arm for both
    /// (`finishClassifierThroughCLI`). The completed run opens no sheet (UX 4, pin F4 of the U30 brief, asked
    /// for by the review of U30 M2, fix 6).
    func testATaxTriageRunReloadsTheSidebarAndSelectsNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runTaxTriageThroughRoute(taxTriageConfig(inputs: made.inputs), made: made)

        try await expectAReloadWithTheResultShown(run)
        XCTAssertNil(run.rig.window.attachedSheet, "a completed TaxTriage run opens no sheet")
    }

    // MARK: - Failed

    /// A failed Kraken2 batch reloads the sidebar, since samples may have left results, and has the
    /// selected row refreshed. The failed folder stays out of the sidebar
    /// (the Kraken2 batch branch of `failClassifierThroughCLI`).
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
        expectsAlert: Bool = false,
        beforeRelease: ((Rig) -> Void)? = nil
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
        beforeRelease?(rig)
        FileManager.default.createFile(atPath: go.path, contents: nil)

        let finished = await waitUntil(timeout: .seconds(30)) { self.item(started.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the row did not finish")
        if expectsAlert {
            _ = await waitUntil(timeout: .seconds(5)) { rig.window.attachedSheet != nil }
        }
        let item = try XCTUnwrap(self.item(started.id))
        return Run(rig: rig, folder: folder, imports: imports, item: item)
    }

    /// Runs a TaxTriage `config` through the `cli` value in the rig of `runThroughRoute`. The stand-in command
    /// plays the captured `complete-project` transcript and holds its last line until the test lets go. The
    /// result the real command leaves is saved in the folder the transcript names, so the sidebar has a result
    /// to show when the row ends. The folder holds the running run record the executor claims it with
    /// (`AnalysesFolder.beginRunInOutputDirectory`), which the row tracks and the stand-in settles at its end,
    /// as the Kraken2 and EsViritu runs of `runThroughRoute` do. It also holds the folder of the sample the
    /// transcript runs, since the sidebar shows a TaxTriage batch only once it counts a sample folder
    /// (`SidebarProjectScanner.classifierBatchSubtitle`).
    func runTaxTriageThroughRoute(_ config: TaxTriageConfig, made: (project: URL, inputs: [URL])) async throws -> Run {
        let imports = made.project.appendingPathComponent("Imports", isDirectory: true)
        let rig = makeRig(project: made.project, selecting: imports)
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-project", root: root)
        let folder = try XCTUnwrap(transcript.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TaxTriageResult(config: config, runtime: 3, exitCode: 0, outputDirectory: folder).save()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("S1", isDirectory: true), withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "TaxTriage", command: "lungfish-cli taxtriage run"), in: folder)
        let go = root.appendingPathComponent("go-\(UUID().uuidString)")
        let cli = try ClassifierRouteFixtures.standInCLI(
            in: root, lines: transcript.lines, holdingTheLastLineUntil: go, settling: AnalysisRunRecord.url(in: folder)
        )
        let routeContext = rig.delegate.currentOperationRouteContext(for: rig.controller)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        rig.delegate.launchTaxTriage(config: config, viewerController: rig.viewer, routeContext: routeContext, cliURLOverride: cli)
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
        let item = try XCTUnwrap(self.item(started.id))
        return Run(rig: rig, folder: folder, imports: imports, item: item)
    }

    func taxTriageConfig(inputs: [URL]) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: inputs.map { TaxTriageSample(sampleId: $0.deletingPathExtension().lastPathComponent, fastq1: $0) },
            outputDirectory: root.appendingPathComponent("Unused/taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "local"
        )
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

    /// Details of an earlier result in the Inspector's Summary, which a finished run must replace.
    static func plantStaleOperationDetails(in rig: Rig) {
        rig.controller.mainSplitViewController.inspectorController.updateBatchOperationDetails(
            tool: "TaxTriage", parameters: ["Stale": "yes"], timestamp: nil, sourceSamples: []
        )
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
