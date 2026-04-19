import XCTest
@testable import LungfishApp

@MainActor
final class MainSplitLayoutTests: XCTestCase {
    func testSidebarUserWidthProducesRestorableWidth() {
        let coordinator = SplitShellWidthCoordinator()

        coordinator.noteProgrammaticWidth(240)
        coordinator.noteObservedWidth(240)
        coordinator.finishProgrammaticWidth()
        coordinator.noteUserRequestedWidth(180)
        coordinator.noteObservedWidth(180)

        XCTAssertTrue(coordinator.hasExplicitUserResize)
        XCTAssertEqual(
            coordinator.restoredUserWidthToApply(
                currentWidth: 320,
                minimumWidth: 180,
                maximumWidth: 720
            ),
            180
        )
    }

    func testSidebarRecommendationIsIgnoredAfterExplicitUserResize() {
        let coordinator = SplitShellWidthCoordinator()

        coordinator.noteProgrammaticWidth(240)
        coordinator.finishProgrammaticWidth()
        coordinator.noteUserRequestedWidth(360)
        coordinator.noteObservedWidth(360)

        XCTAssertTrue(coordinator.hasExplicitUserResize)
        XCTAssertNil(
            coordinator.recommendedWidthToApply(
                proposedWidth: 420,
                minimumWidth: 180,
                maximumWidth: 720,
                currentWidth: 360,
                allowShrink: false
            )
        )
    }

    func testProgrammaticWidthDoesNotMarkExplicitUserResize() {
        let coordinator = SplitShellWidthCoordinator()

        coordinator.noteProgrammaticWidth(320)
        coordinator.noteObservedWidth(320)
        coordinator.finishProgrammaticWidth()

        XCTAssertFalse(coordinator.hasExplicitUserResize)
    }

    func testToolbarDefaultsIncludeSidebarToggleButton() throws {
        let controller = MainWindowController()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let sidebarIdentifier = NSToolbarItem.Identifier("ToggleSidebar")

        XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(sidebarIdentifier))
        XCTAssertTrue(controller.toolbarAllowedItemIdentifiers(toolbar).contains(sidebarIdentifier))

        let item = controller.toolbar(
            toolbar,
            itemForItemIdentifier: sidebarIdentifier,
            willBeInsertedIntoToolbar: true
        )
        XCTAssertEqual(item?.label, "Sidebar")
    }
}
