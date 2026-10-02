import XCTest
import LungfishCore
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport

/// The shell controller defers its layout work with `DispatchQueue.main.async`, and a visibility
/// change queues a restore pass that queues a second pass when it runs. These tests therefore
/// never wait a fixed time. Each wait is a `waitUntil` on the state the next assertion reads, or
/// on a marker queued behind the work the test needs to have run. See `loadedMachineTimeout`.
@MainActor
final class WorkspaceShellLayoutTests: XCTestCase {
    /// Every process-wide defaults key these tests read or the controller writes. The controller
    /// uses `UserDefaults.standard`, so a test saves what it found, starts from none and puts the
    /// saved values back instead of leaving the keys cleared for whatever runs next.
    private nonisolated static let shellLayoutDefaultsKeys = [
        MainSplitViewController.sidebarCollapsedDefaultsKey,
        MainSplitViewController.inspectorCollapsedDefaultsKey,
        MainSplitViewController.sidebarWidthDefaultsKey,
        MainSplitViewController.inspectorWidthDefaultsKey,
        "NSSplitView Subview Frames \(MainSplitViewController.legacyShellAutosaveName)",
    ]

    /// The ceiling for every wait in this file. A wait ends as soon as its condition holds, so the
    /// ceiling only matters when the machine is too loaded to finish the work before it.
    private static let loadedMachineTimeout: Duration = .seconds(30)

    private var savedShellLayoutDefaults: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        savedShellLayoutDefaults = snapshotShellLayoutDefaults()
        // Work an earlier test left on the main queue runs before the keys are cleared.
        await drainMainQueue()
        clearShellLayoutDefaults()
    }

    override func tearDown() async throws {
        // Work this test left on the main queue runs before the saved values go back.
        await drainMainQueue()
        restoreShellLayoutDefaults(savedShellLayoutDefaults)
        savedShellLayoutDefaults = [:]
        try await super.tearDown()
    }

    func testMainSplitExtensionHeadersNameTheirSplitFiles() throws {
        let sourceDirectory = mainSplitViewControllerSourceDirectory()
        for fileName in mainSplitViewControllerSplitExtensionSourceFiles() {
            let source = try String(
                contentsOf: sourceDirectory.appendingPathComponent(fileName),
                encoding: .utf8
            )
            let firstLine = source.split(
                separator: "\n",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init)

            XCTAssertTrue(firstLine?.contains(fileName) == true, "Stale header in \(fileName)")
            XCTAssertFalse(
                firstLine == "// MainSplitViewController.swift - Three-panel split view controller",
                "Split extension should not keep the monolithic MainSplitViewController header"
            )
        }
    }

    func testCoordinatorDoesNotRequestDividerMoveFromResizeCallback() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordUserSidebarWidth(260)
        let decision = coordinator.resizeDecision(
            event: .shellDidResize,
            currentSidebarWidth: 260,
            currentInspectorWidth: 300,
            totalWidth: 1500
        )

        XCTAssertNil(decision.sidebarWidthToPersist)
    }

    func testCoordinatorPrefersRecordedUserWidthOverLateRecommendation() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordRecommendation(320)
        coordinator.recordUserSidebarWidth(220)

        XCTAssertEqual(coordinator.resolvedSidebarWidth(currentWidth: 220), 220)
    }

    func testCoordinatorDoesNotOverwriteUserOwnedWidthDuringOrdinaryShellResize() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordUserSidebarWidth(260)
        let decision = coordinator.resizeDecision(
            event: .shellDidResize,
            currentSidebarWidth: 310,
            currentInspectorWidth: 300,
            totalWidth: 1500
        )

        XCTAssertNil(decision.sidebarWidthToPersist)
        XCTAssertEqual(coordinator.resolvedSidebarWidth(currentWidth: 310), 260)
    }

    func testCoordinatorPersistsSidebarWidthOnlyForExplicitUserDragIntent() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        let decision = coordinator.resizeDecision(
            event: .userDraggedSidebar,
            currentSidebarWidth: 310,
            currentInspectorWidth: 300,
            totalWidth: 1500
        )

        XCTAssertEqual(decision.sidebarWidthToPersist, 310)
        XCTAssertNil(decision.inspectorWidthToPersist)
    }

    func testControllerPersistsUserDraggedShellWidthsAndIgnoresOrdinaryResizeCallbacks() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 310, inspectorWidth: 280, totalWidth: 1500)
        _ = controller.splitView(controller.splitView, constrainSplitPosition: 310, ofSubviewAt: 0)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 310)
        XCTAssertNil(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey))

        controller.testingSetShellFrames(sidebarWidth: 310, inspectorWidth: 330, totalWidth: 1500)
        _ = controller.splitView(controller.splitView, constrainSplitPosition: 1170, ofSubviewAt: 1)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 310)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 330)

        controller.testingSetShellFrames(sidebarWidth: 360, inspectorWidth: 300, totalWidth: 1700)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 310)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 330)
    }

    func testControllerRestoresPersistedShellWidthsFromDefaults() async {
        UserDefaults.standard.set(305, forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        UserDefaults.standard.set(325, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await waitForShellToSettle(controller)
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserSidebarWidth, 305)
        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 325)
        XCTAssertEqual(controller.testingSidebarWidth, 305, accuracy: 2)
        XCTAssertEqual(controller.testingInspectorWidth, 325, accuracy: 2)
    }

    func testControllerClampsPersistedShellWidthsOnNarrowerWindowRestore() async {
        UserDefaults.standard.set(500, forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        UserDefaults.standard.set(430, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1000)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await waitForShellToSettle(controller)
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let sidebarWidth = controller.testingSidebarWidth
        let inspectorWidth = controller.testingInspectorWidth
        let totalSubviewWidth = controller.splitView.bounds.width - (controller.splitView.dividerThickness * 2)

        XCTAssertEqual(controller.testingShellLayoutState.lastUserSidebarWidth, 500)
        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 430)
        XCTAssertLessThanOrEqual(
            sidebarWidth + inspectorWidth,
            totalSubviewWidth - 400 + 1.5,
            "restore must clamp the side panes so the viewer minimum remains available"
        )
        XCTAssertLessThanOrEqual(sidebarWidth, 500)
        XCTAssertLessThanOrEqual(inspectorWidth, 430)
    }

    func testOrdinaryWindowResizeMirrorsLiveSplitWidthsWithoutPersistingClampedWidths() async {
        UserDefaults.standard.set(500, forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        UserDefaults.standard.set(430, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 500, inspectorWidth: 430, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 360, inspectorWidth: 300, totalWidth: 1100)
        controller.testingProcessShellResize()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingSidebarConstraintWidth, 360, accuracy: 0.5)
        XCTAssertEqual(controller.testingInspectorConstraintWidth, 300, accuracy: 0.5)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 500)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 430)
    }

    func testControllerPersistsWideUserDraggedInspectorWidthLikeSidebar() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 640, totalWidth: 1700)
        _ = controller.splitView(controller.splitView, constrainSplitPosition: 1060, ofSubviewAt: 1)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 640)
        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 640)
    }

    func testControllerLetsUserDragInspectorDividerToResizePane() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let dividerPosition = controller.splitView.bounds.width
            - 520
            - controller.splitView.dividerThickness
        let constrainedPosition = controller.splitView(
            controller.splitView,
            constrainSplitPosition: dividerPosition,
            ofSubviewAt: 1
        )
        controller.splitView.setPosition(constrainedPosition, ofDividerAt: 1)
        controller.splitView.adjustSubviews()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingProcessShellResize()

        XCTAssertEqual(controller.testingInspectorWidth, 520, accuracy: 2)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 520)
    }

    func testStackedTrackedSplitResizeClampsRequestedExtent() {
        let splitView = TrackedDividerSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        splitView.isVertical = false

        let leadingView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        let trailingView = NSView(frame: NSRect(x: 0, y: 321, width: 600, height: 179))
        splitView.addArrangedSubview(leadingView)
        splitView.addArrangedSubview(trailingView)
        splitView.setPosition(320, ofDividerAt: 0)

        splitView.bounds.size.height = 420
        let coordinator = TwoPaneTrackedSplitCoordinator()
        coordinator.resizeSubviewsWithOldSize(
            splitView,
            oldSize: NSSize(width: 600, height: 500),
            defaultLeadingFraction: 0.5,
            minimumExtents: (leading: 160, trailing: 200)
        )

        XCTAssertLessThanOrEqual(leadingView.frame.height, 220.5)
        XCTAssertGreaterThanOrEqual(trailingView.frame.height, 199.5)
    }

    func testTrackedSplitRecordsUserDragInsteadOfSnappingBackToOldDivider() {
        let splitView = TrackedDividerSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        splitView.isVertical = true

        let leadingView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let trailingView = NSView(frame: NSRect(x: 321, y: 0, width: 279, height: 500))
        splitView.addArrangedSubview(leadingView)
        splitView.addArrangedSubview(trailingView)

        let coordinator = TwoPaneTrackedSplitCoordinator()
        coordinator.applyInitialSplitPositionIfNeeded(
            to: splitView,
            defaultLeadingFraction: 0.5,
            defaultLeadingExtent: 320,
            minimumExtents: (leading: 100, trailing: 100)
        )

        let dividerThickness = splitView.dividerThickness
        leadingView.frame = NSRect(x: 0, y: 0, width: 220, height: 500)
        trailingView.frame = NSRect(
            x: 220 + dividerThickness,
            y: 0,
            width: 600 - 220 - dividerThickness,
            height: 500
        )

        coordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: (leading: 100, trailing: 100)
        )

        XCTAssertEqual(leadingView.frame.width, 220, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(splitView.requestedDividerPosition(at: 0)), 220, accuracy: 1)
    }

    func testControllerReappliesPersistedSidebarWidthAfterHideThenShow() async {
        UserDefaults.standard.set(320, forKey: MainSplitViewController.sidebarWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserSidebarWidth, 320)
        XCTAssertEqual(controller.testingSidebarWidth, 320, accuracy: 2)

        controller.setSidebarVisible(false, animated: false)
        // The restore pass the hide queued has run before the sidebar comes back.
        await waitForShellToSettle(controller)
        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 320)

        controller.setSidebarVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingProcessShellResize()
        // The reveal restore has run to its end and the laid-out width is the stored one.
        await waitForShellToSettle(controller)
        await waitUntil(timeout: Self.loadedMachineTimeout) {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            return abs(controller.testingSidebarWidth - 320) <= 2
        }

        XCTAssertTrue(controller.isSidebarVisible)
        XCTAssertEqual(controller.testingSidebarWidth, 320, accuracy: 2)
    }

    func testControllerReappliesPersistedInspectorWidthAfterHideThenShow() async {
        UserDefaults.standard.set(340, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 340)
        XCTAssertEqual(controller.testingInspectorWidth, 340, accuracy: 2)

        controller.setInspectorVisible(false, animated: false)
        // The restore pass the hide queued has run before the inspector comes back.
        await waitForShellToSettle(controller)
        XCTAssertFalse(controller.isInspectorVisible)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 340)

        controller.setInspectorVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingProcessShellResize()
        // The reveal restore has run to its end and the laid-out width is the stored one.
        await waitForShellToSettle(controller)
        await waitUntil(timeout: Self.loadedMachineTimeout) {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            return abs(controller.testingInspectorWidth - 340) <= 2
        }

        XCTAssertTrue(controller.isInspectorVisible)
        XCTAssertEqual(controller.testingInspectorWidth, 340, accuracy: 2)
    }

    func testControllerQueuedAnimatedInspectorToggleDoesNotOverwriteStoredWidth() async {
        UserDefaults.standard.set(340, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = await makeController()
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 340)

        controller.setInspectorVisible(false, animated: true, source: "test.queue.hide")
        controller.setInspectorVisible(true, animated: true, source: "test.queue.show")

        // Both animated transitions have finished, and the queued show left the inspector visible.
        await waitUntil(timeout: Self.loadedMachineTimeout) {
            controller.isInspectorVisible && !controller.testingHasPendingShellWork
        }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await waitForShellToSettle(controller)

        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 340)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.inspectorWidthDefaultsKey), 340)
    }

    func testControllerStaleInspectorRecoveryDoesNotBlockLaterUserDragPersistence() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingForceStaleInspectorTransitionSuppression()
        controller.setInspectorVisible(true, animated: false, source: "test.stale.recovery")

        controller.testingSetShellFrames(sidebarWidth: 310, inspectorWidth: 280, totalWidth: 1500)
        _ = controller.splitView(controller.splitView, constrainSplitPosition: 310, ofSubviewAt: 0)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 310)
    }

    func testCoordinatorRestoresStoredSidebarWidthWhenInspectorBecomesHidden() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 720,
            inspectorMinWidth: 200,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordUserSidebarWidth(500)
        coordinator.recordUserInspectorWidth(430)
        coordinator.setSidebarVisible(true)
        coordinator.setInspectorVisible(true)

        let clampedWidths = coordinator.resolvedShellWidths(
            currentSidebarWidth: 240,
            currentInspectorWidth: 280,
            totalWidth: 1000
        )

        XCTAssertLessThan(clampedWidths.sidebarWidth, 500)
        XCTAssertLessThan(clampedWidths.inspectorWidth, 430)

        coordinator.setInspectorVisible(false)
        let sidebarOnlyWidths = coordinator.resolvedShellWidths(
            currentSidebarWidth: clampedWidths.sidebarWidth,
            currentInspectorWidth: 0,
            totalWidth: 1000
        )

        XCTAssertEqual(sidebarOnlyWidths.sidebarWidth, 500, accuracy: 0.5)
        XCTAssertEqual(sidebarOnlyWidths.inspectorWidth, 0, accuracy: 0.5)
    }

    func testControllerDeferredSidebarRecommendationDoesNotOverwriteFreshUserDrag() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        NotificationCenter.default.post(
            name: .sidebarPreferredWidthRecommended,
            object: self,
            userInfo: ["width": CGFloat(320), NotificationUserInfoKey.windowStateScope: controller.windowStateScope]
        )

        controller.testingSetShellFrames(sidebarWidth: 260, inspectorWidth: 280, totalWidth: 1500)
        _ = controller.splitView(controller.splitView, constrainSplitPosition: 260, ofSubviewAt: 0)
        controller.testingProcessShellResize()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 260)

        // The deferred recommendation has run before the check that it did not win.
        await waitForShellToSettle(controller)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 260)
        XCTAssertEqual(controller.testingSidebarConstraintWidth, 260, accuracy: 2)
    }

    func testControllerIgnoresSidebarRecommendationFromDifferentWindowScope() async {
        let (controller, window) = await makeController()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        NotificationCenter.default.post(
            name: .sidebarPreferredWidthRecommended,
            object: self,
            userInfo: [
                "width": CGFloat(360),
                NotificationUserInfoKey.windowStateScope: WindowStateScope()
            ]
        )

        // Work an accepted recommendation would have queued has run before the check that none applied.
        await waitForShellToSettle(controller)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(controller.testingSidebarConstraintWidth, 360, accuracy: 0.5)
    }

    func testFocusViewerCollapsesBothSidePanesAndRestoreShowsThemAgain() async {
        let (controller, window) = await makeController()
        controller.testingSetShellFrames(sidebarWidth: 320, inspectorWidth: 340, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        controller.focusViewer()
        await waitForShellToSettle(controller)

        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertFalse(controller.isInspectorVisible)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: MainSplitViewController.sidebarCollapsedDefaultsKey))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: MainSplitViewController.inspectorCollapsedDefaultsKey))

        controller.restoreSidePanes()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await waitForShellToSettle(controller)

        XCTAssertTrue(controller.isSidebarVisible)
        XCTAssertTrue(controller.isInspectorVisible)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: MainSplitViewController.sidebarCollapsedDefaultsKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: MainSplitViewController.inspectorCollapsedDefaultsKey))
    }

    private func makeController() async -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        // The first layout queued the initial restore of the persisted widths.
        await waitForShellToSettle(controller)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await waitForShellToSettle(controller)
        return (controller, window)
    }

    /// Returns once every block already queued on the main queue has run.
    ///
    /// The controller defers layout work with `DispatchQueue.main.async`, and the main queue runs
    /// its blocks in the order they were queued. A marker queued now therefore runs after all of
    /// that work, however long a loaded machine takes to get there.
    private func drainMainQueue() async {
        let marker = MainQueueMarker()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { marker.hasRun = true }
        }
        await waitUntil(timeout: Self.loadedMachineTimeout) { marker.hasRun }
    }

    /// Returns once the shell has run the layout work its last change queued.
    ///
    /// A restore pass queues a second pass when it runs, so the main queue is drained twice. The
    /// controller's own flags must then show no reveal, transition or suppression left pending.
    private func waitForShellToSettle(_ controller: MainSplitViewController) async {
        await drainMainQueue()
        await drainMainQueue()
        await waitUntil(timeout: Self.loadedMachineTimeout) { !controller.testingHasPendingShellWork }
    }

    private nonisolated func clearShellLayoutDefaults() {
        let defaults = UserDefaults.standard
        for key in Self.shellLayoutDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private nonisolated func snapshotShellLayoutDefaults() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in Self.shellLayoutDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    private nonisolated func restoreShellLayoutDefaults(_ snapshot: [String: Any]) {
        let defaults = UserDefaults.standard
        for key in Self.shellLayoutDefaultsKeys {
            if let value = snapshot[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private nonisolated func storedCGFloat(forKey key: String) -> CGFloat? {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
        return CGFloat(number.doubleValue)
    }
}

/// A flag the main queue sets once it reaches a block queued behind other work.
@MainActor
private final class MainQueueMarker {
    var hasRun = false
}

/// Shell-layout probes and drivers for these tests. They read and drive
/// internal `MainSplitViewController` state through `@testable import`.
private extension MainSplitViewController {
    var testingShellLayoutState: WorkspaceShellLayoutState {
        shellLayoutCoordinator.state
    }

    /// Whether a visibility change, a reveal restore or an inspector transition still has work the
    /// controller tracks. That covers a pending reveal or reveal width, a transition in flight or
    /// queued, and a programmatic resize suppression that has not been released.
    var testingHasPendingShellWork: Bool {
        pendingSidebarRevealRestore
            || pendingInspectorRevealRestore
            || pendingSidebarRevealWidth != nil
            || pendingInspectorRevealWidth != nil
            || inspectorTransitionInFlight
            || queuedInspectorCollapsedState != nil
            || programmaticShellResizeSuppressionDepth > 0
    }

    var testingSidebarWidth: CGFloat {
        sidebarContainerView?.frame.width ?? 0
    }

    var testingInspectorWidth: CGFloat {
        inspectorContainerView?.frame.width ?? 0
    }

    var testingSidebarConstraintWidth: CGFloat {
        sidebarWidthConstraint?.constant ?? 0
    }

    var testingInspectorConstraintWidth: CGFloat {
        inspectorWidthConstraint?.constant ?? 0
    }

    func testingSetShellFrames(
        sidebarWidth: CGFloat,
        inspectorWidth: CGFloat,
        totalWidth: CGFloat,
        height: CGFloat = 900
    ) {
        guard let sidebarContainerView, let viewerContainerView, let inspectorContainerView else { return }

        let dividerThickness = splitView.dividerThickness
        let viewerWidth = totalWidth - sidebarWidth - inspectorWidth - (dividerThickness * 2)
        let resolvedViewerWidth = max(viewerWidth, viewerMinWidth)
        let resolvedTotalWidth = sidebarWidth + resolvedViewerWidth + inspectorWidth + (dividerThickness * 2)
        view.frame = NSRect(x: 0, y: 0, width: resolvedTotalWidth, height: height)
        splitView.frame = view.bounds
        splitView.bounds = view.bounds
        sidebarContainerView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        viewerContainerView.frame = NSRect(
            x: sidebarWidth + dividerThickness,
            y: 0,
            width: resolvedViewerWidth,
            height: height
        )
        inspectorContainerView.frame = NSRect(
            x: resolvedTotalWidth - inspectorWidth,
            y: 0,
            width: inspectorWidth,
            height: height
        )
    }

    func testingProcessShellResize() {
        splitViewDidResizeSubviews(Notification(name: Notification.Name("WorkspaceShellLayoutTests.Resize"), object: splitView))
    }

    func testingRestorePersistedShellLayout() {
        restorePanelState()
        restorePersistedShellLayout()
    }

    func testingForceStaleInspectorTransitionSuppression() {
        inspectorTransitionInFlight = true
        inspectorTransitionStartTime = ProcessInfo.processInfo.systemUptime - 1.0
        inspectorTransitionTargetCollapsedState = inspectorItem.isCollapsed
        queuedInspectorCollapsedState = nil
        programmaticShellResizeSuppressionDepth = 1
    }
}
