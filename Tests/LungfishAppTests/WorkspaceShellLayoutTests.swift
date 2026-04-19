import XCTest
@testable import LungfishApp

@MainActor
final class WorkspaceShellLayoutTests: XCTestCase {
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

        XCTAssertFalse(decision.shouldSetSidebarDividerSynchronously)
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
}
