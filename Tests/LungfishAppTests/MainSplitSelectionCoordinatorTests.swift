import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class MainSplitSelectionCoordinatorTests: XCTestCase {
    func testStaleDelayedSelectionCommitCannotMutateInspectorAfterNewerSelectionBecomesActive() {
        let controller = MainSplitViewController()
        _ = controller.view

        let first = ContentSelectionIdentity(
            url: URL(fileURLWithPath: "/tmp/A.naomgs"),
            kind: "naoMgsResult"
        )
        let second = ContentSelectionIdentity(
            url: URL(fileURLWithPath: "/tmp/B.nvd"),
            kind: "nvdResult"
        )

        let firstToken = controller.testingBeginDisplayRequest(identity: first)
        let secondToken = controller.testingBeginDisplayRequest(identity: second)
        controller.inspectorController.viewModel.selectedItem = "Current"

        controller.testingCommitDisplayRequest(firstToken, identity: first) {
            controller.inspectorController.viewModel.selectedItem = "Stale"
        }

        XCTAssertEqual(controller.inspectorController.viewModel.selectedItem, "Current")

        controller.testingCommitDisplayRequest(secondToken, identity: second) {
            controller.inspectorController.viewModel.selectedItem = "Fresh"
        }

        XCTAssertEqual(controller.inspectorController.viewModel.selectedItem, "Fresh")
    }

    func testContextMenuOpenRoutesThroughExplicitDisplayDelegate() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitContextMenu-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let fastaURL = projectURL.appendingPathComponent("example.fasta")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))
        delegate.selectedItems.removeAll()

        sidebar.perform(NSSelectorFromString("contextMenuOpen:"), with: nil)

        XCTAssertEqual(
            delegate.selectedItems.compactMap { $0.url?.resolvingSymlinksInPath() },
            [fastaURL.resolvingSymlinksInPath()]
        )
    }

    func testInspectorDocumentModeRequestAfterDownloadIncludesWindowScope() {
        let controller = MainSplitViewController()
        _ = controller.view

        let capture = MainSplitNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .showInspectorRequested,
            object: nil,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.testingRequestInspectorDocumentModeAfterDownload()

        XCTAssertEqual(
            capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope,
            controller.testingWindowStateScope
        )
    }
}

@MainActor
private final class SidebarSelectionSpy: SidebarSelectionDelegate {
    var selectedItems: [SidebarItem] = []

    func sidebarDidSelectItem(_ item: SidebarItem?) {
        if let item {
            selectedItems.append(item)
        }
    }

    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        selectedItems.append(contentsOf: items)
    }
}

private final class MainSplitNotificationUserInfoCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedUserInfo: [AnyHashable: Any]?

    var userInfo: [AnyHashable: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedUserInfo
    }

    func record(_ notification: Notification) {
        lock.lock()
        capturedUserInfo = notification.userInfo
        lock.unlock()
    }
}
