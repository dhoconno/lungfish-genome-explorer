import XCTest
@testable import LungfishApp

@MainActor
final class WorkspaceShellLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        clearShellLayoutDefaults()
    }

    override func tearDown() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        clearShellLayoutDefaults()
        super.tearDown()
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

    func testControllerPersistsUserDraggedShellWidthsAndIgnoresOrdinaryResizeCallbacks() {
        let (controller, window) = makeController()
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

    func testControllerRestoresPersistedShellWidthsFromDefaults() {
        UserDefaults.standard.set(305, forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        UserDefaults.standard.set(325, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserSidebarWidth, 305)
        XCTAssertEqual(controller.testingShellLayoutState.lastUserInspectorWidth, 325)
        XCTAssertEqual(controller.testingSidebarWidth, 305, accuracy: 2)
        XCTAssertEqual(controller.testingInspectorWidth, 325, accuracy: 2)
    }

    func testControllerClampsPersistedShellWidthsOnNarrowerWindowRestore() {
        UserDefaults.standard.set(500, forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        UserDefaults.standard.set(430, forKey: MainSplitViewController.inspectorWidthDefaultsKey)

        let (controller, window) = makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1000)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

    func testControllerReappliesPersistedSidebarWidthAfterHideThenShow() {
        UserDefaults.standard.set(320, forKey: MainSplitViewController.sidebarWidthDefaultsKey)

        let (controller, window) = makeController()
        controller.testingSetShellFrames(sidebarWidth: 240, inspectorWidth: 280, totalWidth: 1500)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingRestorePersistedShellLayout()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.testingShellLayoutState.lastUserSidebarWidth, 320)
        XCTAssertEqual(controller.testingSidebarWidth, 320, accuracy: 2)

        controller.setSidebarVisible(false, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertEqual(storedCGFloat(forKey: MainSplitViewController.sidebarWidthDefaultsKey), 320)

        controller.setSidebarVisible(true, animated: false)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.testingProcessShellResize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.isSidebarVisible)
        XCTAssertEqual(controller.testingSidebarWidth, 320, accuracy: 2)
    }

    private func makeController() -> (MainSplitViewController, NSWindow) {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (controller, window)
    }

    private nonisolated func clearShellLayoutDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: MainSplitViewController.sidebarCollapsedDefaultsKey)
        defaults.removeObject(forKey: MainSplitViewController.inspectorCollapsedDefaultsKey)
        defaults.removeObject(forKey: MainSplitViewController.sidebarWidthDefaultsKey)
        defaults.removeObject(forKey: MainSplitViewController.inspectorWidthDefaultsKey)
        defaults.removeObject(forKey: "NSSplitView Subview Frames \(MainSplitViewController.legacyShellAutosaveName)")
    }

    private nonisolated func storedCGFloat(forKey key: String) -> CGFloat? {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
        return CGFloat(number.doubleValue)
    }
}
