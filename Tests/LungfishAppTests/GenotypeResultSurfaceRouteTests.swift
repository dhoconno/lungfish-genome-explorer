// GenotypeResultSurfaceRouteTests.swift - The genotype viewer on the surface host keeps a person's edits (Phase 3.2 lane GENO)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Removing a genotype viewer is work, not chrome. A matrix edit made while the workbook is being published waits in the
// controller's queue, so the removal keeps the controller until that edit is saved, cuts its callbacks and takes its
// actions out of Undo. These tests hold the publication lock so the edit stays queued, take the viewer away by each way
// it can leave, then free the lock and read the edit from the bundle's file.
//
// Each test opens the result in a real window through the sidebar's `displayContent(for:)`.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishIO
@testable import LungfishKit

/// What the bundle's own file says went wrong. A real load throws this kind of error, not a `SurfaceError`.
private struct DamagedResultFile: LocalizedError {
    var errorDescription: String? { "genotype-result.json could not be read." }
}

/// A surface whose load fails on the file. `onLoad` runs first, so a test can read what the removal had done by then.
@MainActor
private final class RefusingSurface: ResultViewport {
    let controller = NSViewController()
    let surfaceKind: SurfaceKind
    let onLoad: () -> Void

    init(kind: SurfaceKind, onLoad: @escaping () -> Void = {}) {
        surfaceKind = kind
        self.onLoad = onLoad
    }

    var viewController: NSViewController { controller }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        onLoad()
        throw DamagedResultFile()
    }
}

/// Holds the retry the controller asks for until the test frees the lock.
private final class HeldRetryScheduler: GenotypeMatrixAnnotationRetryScheduling {
    private final class Cancellation: GenotypeMatrixAnnotationRetryCancellation {
        func cancel() {}
    }

    private var actions: [@MainActor () -> Void] = []
    var pendingCount: Int { actions.count }

    func schedule(_ action: @escaping @MainActor () -> Void) -> GenotypeMatrixAnnotationRetryCancellation {
        actions.append(action)
        return Cancellation()
    }

    @MainActor
    func fire() {
        let pending = actions
        actions.removeAll()
        pending.forEach { $0() }
    }
}

@MainActor
final class GenotypeResultSurfaceRouteTests: XCTestCase {
    /// A matrix edit that waits behind a held publication lock, with an Undo the controller registered. The controller
    /// is held weakly, so it stays alive only when the removal keeps it, and `controllerID` finds it in that store.
    private struct HeldEdit {
        weak var controller: GenotypeResultViewController?
        let controllerID: ObjectIdentifier
        let bundleURL: URL
        let body: String
        let lock: ONTGenotypeBundlePublicationLock
        let scheduler: HeldRetryScheduler
        let undoManager: UndoManager
    }

    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "GenotypeSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The surface

    func testTheGenotypeViewerOpensThroughTheSurfaceHost() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let item = try await buildRow(of: "Genotype")

        harness.select(item)
        let opened = await waitUntil(budget: .lookup) { harness.split.viewerController.genotypeResultViewController != nil }

        XCTAssertTrue(opened, "the genotype viewer never opened")
        let viewer = harness.split.viewerController!
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .bundle(.genotypeResult))
        XCTAssertEqual(viewer.children.filter { $0 is GenotypeResultViewController }.count, 1)
    }

    // MARK: - Every way the viewer leaves

    /// Another row in the sidebar, for each kind of the matrix: the viewer goes, its Undo goes, and the edit is saved.
    func testEveryKindOfTheMatrixTakesTheEditToItsSaveStep() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let genotype = try await buildRow(of: "Genotype")
        for kind in ViewSwitchKinds.all where kind.name != "Genotype" {
            let next = try await buildRow(of: kind.name)
            let edit = try await holdAnEdit(in: harness, row: genotype, body: "survive \(kind.name)")

            harness.select(next)

            let left = await waitUntil(budget: .lookup) { harness.split.viewerController.genotypeResultViewController == nil }
            XCTAssertTrue(left, "\(kind.name) left the genotype viewer on screen")
            XCTAssertFalse(edit.undoManager.canUndo, "\(kind.name) left an Undo that targets a controller that has gone")
            XCTAssertNil(edit.controller?.onSelectionStateChanged, "\(kind.name) left the viewer's callbacks attached")
            try await assertTheEditIsSaved(edit, leftBy: kind.name)
        }
    }

    /// A project switch clears the viewer through the same reset the open commits with.
    func testAProjectSwitchTakesTheEditToItsSaveStep() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let edit = try await holdAnEdit(in: harness, row: try await buildRow(of: "Genotype"), body: "survive project switch")

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(harness.split.viewerController.genotypeResultViewController)
        XCTAssertFalse(edit.undoManager.canUndo)
        try await assertTheEditIsSaved(edit, leftBy: "a project switch")
    }

    /// A window close runs the removal while the window still answers, and the edit is saved after the window, the split
    /// and the viewer have gone.
    func testClosingTheWindowTakesTheEditToItsSaveStep() async throws {
        var harness: ViewSwitchWindowHarness? = try ViewSwitchWindowHarness()
        let row = try await buildRow(of: "Genotype")
        let edit = try await holdAnEdit(in: harness!, row: row, body: "survive window close")
        let bundleURL = edit.bundleURL
        let body = edit.body
        let lock = edit.lock
        let scheduler = edit.scheduler
        let undoManager = edit.undoManager
        weak var weakController: GenotypeResultViewController? = edit.controller

        harness!.controller.close()

        XCTAssertNil(harness!.split.viewerController.genotypeResultViewController, "the window closed with the viewer still in place")
        XCTAssertFalse(undoManager.canUndo, "the closed window's Undo still targets the controller")
        harness!.split.invalidateDisplayRequest()
        harness!.split.inspectorController.clearSelection()
        harness = nil

        XCTAssertNotNil(weakController, "the queued edit went with the window")
        lock.release()
        scheduler.fire()
        await waitForAnnotationEdits()
        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertTrue(saved.matrixComments.contains { $0.body == body }, "a window close lost the edit")
    }

    /// A window close takes the split with it. The window, the edit and the close all happen inside one closure, so
    /// nothing in this test holds the split, the viewer or the controller afterwards, and the split is shown to be gone
    /// before the edit is read back. A controller that is alive for another reason cannot hide a lost edit.
    func testAWindowCloseKeepsTheQueuedEditAfterTheSplitIsReleased() async throws {
        let row = try await buildRow(of: "Genotype")
        let body = "survive a window close and a released split"
        weak var weakSplit: MainSplitViewController?
        weak var weakController: GenotypeResultViewController?
        var controllerID: ObjectIdentifier?
        let queued = try await { () async throws -> (bundleURL: URL, lock: ONTGenotypeBundlePublicationLock, scheduler: HeldRetryScheduler) in
            let harness = try ViewSwitchWindowHarness()
            let edit = try await self.holdAnEdit(in: harness, row: row, body: body)
            weakSplit = harness.split
            weakController = edit.controller
            controllerID = edit.controllerID
            harness.controller.close()
            // Not `harness.close()`: it clears the viewport through the host, which runs the same removal, so a window
            // close whose own removal had been lost would still look kept.
            harness.split.invalidateDisplayRequest()
            harness.split.inspectorController.clearSelection()
            return (edit.bundleURL, edit.lock, edit.scheduler)
        }()

        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the split is still alive, so this test cannot tell a lost edit from a kept one")
        XCTAssertNotNil(weakController, "the queued edit's controller went with the split")
        XCTAssertNotNil(
            controllerID.flatMap { MainSplitViewController.retainedDeferredGenotypeResultControllers[$0] },
            "a window close did not keep the controller in the store"
        )
        queued.lock.release()
        queued.scheduler.fire()
        await waitForAnnotationEdits()
        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: queued.bundleURL)
        XCTAssertTrue(
            saved.matrixComments.contains { $0.body == body },
            "a window close lost the edit: \(saved.matrixComments.map(\.body))"
        )
    }

    /// The app's own close handler drops the window's controller from its list. It removes the genotype viewer first,
    /// with no call of the window's delegate before it, so the order of the two notifications cannot lose the edit.
    func testTheAppsCloseHandlerRunsTheGenotypeRemovalBeforeItDropsTheController() async throws {
        let app = makeAppDelegateWithTemporaryState()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        app.testingSetMainWindowControllers([harness.controller])
        let viewer = harness.split.viewerController!
        let edit = try await holdAnEdit(in: harness, row: try await buildRow(of: "Genotype"), body: "survive the app's close handler")

        _ = app.perform(
            NSSelectorFromString("windowWillClose:"),
            with: Notification(name: NSWindow.willCloseNotification, object: harness.window)
        )

        XCTAssertNil(viewer.genotypeResultViewController, "the app's close handler left the viewer in place")
        XCTAssertFalse(edit.undoManager.canUndo, "the app's close handler left an Undo that targets the controller")
        XCTAssertTrue(app.testingMainWindowControllers.isEmpty, "the app's close handler kept the window's controller")
        try await assertTheEditIsSaved(edit, leftBy: "the app's close handler")
    }

    // MARK: - A refusal of the next surface

    /// The removal runs before the next surface loads, so a load that throws finds the edit already kept.
    func testTheRemovalWorkRunsBeforeTheNextSurfaceLoadsAndSurvivesItsRefusal() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let edit = try await holdAnEdit(in: harness, row: try await buildRow(of: "Genotype"), body: "survive a refusal")
        var loaded = false
        var undoAtLoad = true
        var callbackAtLoad = true
        let next = SurfaceKind.bundle(.primerAnalysis)
        viewer.surfaceHost.registry.register(next) {
            RefusingSurface(kind: next) {
                loaded = true
                undoAtLoad = edit.undoManager.canUndo
                callbackAtLoad = edit.controller?.onSelectionStateChanged != nil
            }
        }

        viewer.surfaceHost.show(kind: next, input: ())

        XCTAssertTrue(loaded)
        XCTAssertFalse(undoAtLoad, "the next surface loaded with Undo still on the controller")
        XCTAssertFalse(callbackAtLoad, "the next surface loaded with the viewer's callbacks attached")
        XCTAssertNil(viewer.genotypeResultViewController)
        try await assertTheEditIsSaved(edit, leftBy: "a refused surface")
    }

    /// A second genotype result that refuses leaves the first one's edit to its save step, and the workbook still shows.
    func testASecondGenotypeResultThatRefusesKeepsTheFirstEditAndShowsTheWorkbook() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try await buildRow(of: "Genotype")
        let edit = try await holdAnEdit(in: harness, row: row, body: "survive a second result")
        let kind = SurfaceKind.bundle(.genotypeResult)
        viewer.surfaceHost.registry.register(kind) { RefusingSurface(kind: kind) }

        harness.select(row)

        let fellBack = await waitUntil(budget: .lookup) { viewer.testQuickLookURL != nil }
        XCTAssertTrue(fellBack, "the workbook preview never opened")
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the genotype result."), "the workbook replaced the viewer with no words: \(words)")
        XCTAssertTrue(words.contains("genotype-result.json could not be read."), words)
        XCTAssertNil(viewer.genotypeResultViewController)
        XCTAssertFalse(edit.undoManager.canUndo)
        try await assertTheEditIsSaved(edit, leftBy: "a second result that refused")
    }

    // MARK: - The words

    /// A surface that refuses on the file says what happened and what to try, with no internal kind id, and leaves
    /// neither a viewer nor an Inspector document behind. This result has no workbook to fall back on.
    func testAGenotypeResultThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let url = root.appendingPathComponent("no-workbook.lungfishgenotype", isDirectory: true)
        let result = Self.makeResult(at: url)
        harness.split.genotypeResultLoader = { _ in result }
        let kind = SurfaceKind.bundle(.genotypeResult)
        viewer.surfaceHost.registry.register(kind) { RefusingSurface(kind: kind) }

        harness.split.displayGenotypeResultBundleFromSidebar(at: url)

        try await assertTheRouteSaysItDidNotOpen(harness)
    }

    /// The bundle's file that does not read takes the same words, where the base said only "No sequence selected".
    func testAGenotypeFileThatDoesNotReadSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let url = root.appendingPathComponent("unreadable.lungfishgenotype", isDirectory: true)
        harness.split.genotypeResultLoader = { _ in throw DamagedResultFile() }

        harness.split.displayGenotypeResultBundleFromSidebar(at: url)

        try await assertTheRouteSaysItDidNotOpen(harness)
    }

    // MARK: - Support

    private func assertTheRouteSaysItDidNotOpen(
        _ harness: ViewSwitchWindowHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let viewer = harness.split.viewerController!
        let words = { viewer.statusBar.positionLabel.stringValue }
        let said = await waitUntil(budget: .lookup) { words().contains("Unable to open the genotype result.") }
        XCTAssertTrue(said, "the status line never said the result did not open: \(words())", file: file, line: line)
        XCTAssertTrue(words().contains("genotype-result.json could not be read."), words(), file: file, line: line)
        XCTAssertTrue(words().contains("Select the item again."), words(), file: file, line: line)
        XCTAssertFalse(words().contains("bundle:"), "the words name an internal kind id: \(words())", file: file, line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, "the words are in a hidden status bar", file: file, line: line)
        XCTAssertNil(viewer.genotypeResultViewController, file: file, line: line)
        XCTAssertNil(
            harness.split.inspectorController.viewModel.documentSectionViewModel.genotypeResultDocument,
            "the Inspector describes a result that is not shown",
            file: file,
            line: line
        )
    }

    /// Builds the sidebar row of one matrix kind under its own folder.
    private func buildRow(of name: String) async throws -> SidebarItem {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name }, "the matrix has no kind \(name)")
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind), "\(name) names no routing row")
        let kindRoot = try SafetyNetFiles.makeDirectory(
            root.appendingPathComponent(kind.folder + "-" + UUID().uuidString, isDirectory: true)
        )
        return try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot))).item
    }

    /// Opens the genotype row and makes an edit that waits behind a held publication lock, with its first try done.
    private func holdAnEdit(in harness: ViewSwitchWindowHarness, row: SidebarItem, body: String) async throws -> HeldEdit {
        let viewer = harness.split.viewerController!
        harness.select(row)
        let opened = await waitUntil(budget: .lookup) { viewer.genotypeResultViewController != nil }
        XCTAssertTrue(opened, "the genotype viewer never opened")
        let controller = try XCTUnwrap(viewer.genotypeResultViewController)
        let scheduler = HeldRetryScheduler()
        controller.matrixAnnotationRetryScheduler = scheduler
        let bundleURL = try XCTUnwrap(controller.currentResultBundleURL)
        let lock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)
        controller.editMatrixComment(.init(targets: [.column(sample: "DW472")], intent: .upsert(body: body)))
        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 1, "the edit did not wait behind the lock")
        let waiting = await waitUntil(budget: .lookup) { scheduler.pendingCount > 0 }
        XCTAssertTrue(waiting, "the edit never asked for its retry")
        let undoManager = try XCTUnwrap(controller.view.window?.undoManager)
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: controller) { _ in
            XCTFail("Undo reached a genotype controller that has gone")
        }
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo)
        return HeldEdit(
            controller: controller,
            controllerID: ObjectIdentifier(controller),
            bundleURL: bundleURL,
            body: body,
            lock: lock,
            scheduler: scheduler,
            undoManager: undoManager
        )
    }

    /// Checks that the removal kept the controller and its edit, frees the lock, fires the held retry and reads the
    /// edit back from the bundle's file. The controller is kept by the store alone, since the edit holds it weakly.
    private func assertTheEditIsSaved(
        _ edit: HeldEdit,
        leftBy way: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertNotNil(edit.controller, "\(way) let the controller go with its edit still waiting", file: file, line: line)
        XCTAssertNotNil(
            MainSplitViewController.retainedDeferredGenotypeResultControllers[edit.controllerID],
            "\(way) did not keep the controller in the store",
            file: file,
            line: line
        )
        edit.lock.release()
        edit.scheduler.fire()
        await waitForAnnotationEdits()
        XCTAssertNil(
            MainSplitViewController.retainedDeferredGenotypeResultControllers[edit.controllerID],
            "\(way) kept the controller after its edit was saved",
            file: file,
            line: line
        )
        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: edit.bundleURL)
        XCTAssertTrue(
            saved.matrixComments.contains { $0.body == edit.body },
            "\(way) lost the edit: \(saved.matrixComments.map(\.body))",
            file: file,
            line: line
        )
    }

    private static func makeResult(at url: URL) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: url,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "surface-route",
                analysisName: "surface-route",
                primaryWorkbookPath: "surface-route.xlsx",
                longSummaryCSVPath: "surface-route.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "surface-route.retained-demux-samples.csv",
                statsJSONPath: "surface-route.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: url.appendingPathComponent("surface-route.xlsx"),
                longSummaryCSVURL: url.appendingPathComponent("surface-route.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: url.appendingPathComponent("surface-route.retained-demux-samples.csv"),
                statsJSONURL: url.appendingPathComponent("surface-route.retained-demux-stats.json"),
                provenanceURL: url.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1, retainedUniqueReads: 1),
            calls: [],
            samples: []
        )
    }
}
