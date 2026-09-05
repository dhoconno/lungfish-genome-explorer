import XCTest
import AppKit
import LungfishKit
@testable import LungfishApp

@MainActor
final class ProjectSessionRegistryTests: XCTestCase {
    func testExplicitClosedOperationRouteNeverFallsBackToUnrelatedWindow() {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let unrelated = MainWindowController(window: nil, projectSession: ProjectSession())
        delegate.mainWindowController = unrelated
        let route = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/closed-origin.lungfish"),
            windowStateScope: WindowStateScope()
        )
        XCTAssertNil(delegate.targetMainWindowController(routeContext: route))
        XCTAssertTrue(delegate.targetMainWindowController(routeContext: nil) === unrelated)
    }

    func testClosedExplicitWindowDoesNotStealSelectionInSameProjectPeer() {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let projectURL = URL(fileURLWithPath: "/tmp/shared-project.lungfish")
        let peer = ProjectSession()
        peer.openReadOnlyFilesystemFallback(at: projectURL)
        delegate.mainWindowController = MainWindowController(window: nil, projectSession: peer)
        let route = OperationRouteContext(projectURL: projectURL, windowStateScope: WindowStateScope())
        XCTAssertNil(delegate.targetMainWindowController(routeContext: route))
    }

    func testProjectlessOperationOriginNeverBorrowsGlobalWorkingDirectory() {
        let delegate = makeAppDelegateWithTemporaryState()
        delegate.workingDirectoryURL = URL(fileURLWithPath: "/tmp/unrelated.lungfish")
        let controller = MainWindowController(window: nil, projectSession: ProjectSession())
        let route = delegate.currentOperationRouteContext(for: controller)
        XCTAssertNil(route?.projectURL)
        XCTAssertEqual(route?.windowStateScopeID, controller.projectSession.windowStateScope.id)
    }

    func testProjectlessRouteRejectsWindowThatNowBrowsesFolder() throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        let route = delegate.currentOperationRouteContext(for: controller)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RouteFolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        controller.mainSplitViewController.sidebarController.openProject(at: folder)
        XCTAssertNil(controller.projectSession.projectURL)
        XCTAssertNil(delegate.targetMainWindowController(routeContext: route))
        let currentRoute = delegate.currentOperationRouteContext(for: controller)
        XCTAssertEqual(currentRoute?.projectURL?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertTrue(delegate.targetMainWindowController(routeContext: currentRoute) === controller)
    }

    func testRegistersMultipleSessionsForSameCanonicalProjectURL() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()

        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url.standardizedFileURL)

        XCTAssertEqual(registry.sessions(forProjectURL: url).count, 2)
        XCTAssertEqual(registry.windowNumber(for: first), 1)
        XCTAssertEqual(registry.windowNumber(for: second), 2)
    }

    func testUnregisterRemovesOnlyThatSession() {
        let registry = ProjectSessionRegistry()
        let url = URL(fileURLWithPath: "/tmp/Shared.lungfish", isDirectory: true)
        let first = ProjectSession()
        let second = ProjectSession()
        registry.register(first, projectURL: url)
        registry.register(second, projectURL: url)

        registry.unregister(first)

        XCTAssertEqual(registry.sessions(forProjectURL: url).map(\.id), [second.id])
    }
}
