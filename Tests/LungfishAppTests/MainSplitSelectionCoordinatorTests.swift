import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class MainSplitSelectionCoordinatorTests: XCTestCase {
    func testShowInspectorRequestIgnoresScopedNotificationFromDifferentWindow() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(controller.isInspectorVisible)
    }

    func testShowInspectorRequestStillAcceptsLegacyUnscopedNotification() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(name: .showInspectorRequested, object: nil)

        XCTAssertTrue(controller.isInspectorVisible)
    }

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

    func testContextMenuShowInInspectorIncludesWindowScope() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitShowInspector")
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let scope = WindowStateScope()
        sidebar.windowStateScope = scope

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        let capture = MainSplitNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .showInspectorRequested,
            object: sidebar,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sidebar.perform(NSSelectorFromString("contextMenuShowInInspector:"), with: nil)

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }

    func testNavigateToSidebarItemIgnoresScopedNotificationFromDifferentWindow() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitNavigateScoped")
        let otherURL = projectURL.appendingPathComponent("other.fasta")
        try ">other\nTGCA\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.windowStateScope = WindowStateScope()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        NotificationCenter.default.post(
            name: .navigateToSidebarItem,
            object: nil,
            userInfo: [
                "url": otherURL,
                NotificationUserInfoKey.windowStateScope: WindowStateScope(),
            ]
        )

        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), fastaURL.resolvingSymlinksInPath())
    }

    func testNavigateToSidebarItemStillAcceptsLegacyUnscopedNotification() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitNavigateLegacy")
        let otherURL = projectURL.appendingPathComponent("other.fasta")
        try ">other\nTGCA\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.windowStateScope = WindowStateScope()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        NotificationCenter.default.post(
            name: .navigateToSidebarItem,
            object: nil,
            userInfo: ["url": otherURL]
        )

        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), otherURL.resolvingSymlinksInPath())
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

    func testStaleDatabaseBuildCompletionCannotCommitAfterNewerSelectionBecomesActive() {
        let controller = MainSplitViewController()
        _ = controller.view

        let resultURL = URL(fileURLWithPath: "/tmp/kraken2-batch-stale")
        let databaseBuildRequest = controller.testingBeginDatabaseBuildRequest(
            tool: "Kraken2",
            resultURL: resultURL
        )
        _ = controller.testingBeginDisplayRequest(
            identity: ContentSelectionIdentity(
                url: URL(fileURLWithPath: "/tmp/newer.fasta"),
                kind: "sequence"
            )
        )

        var didCommit = false
        controller.testingCommitDatabaseBuildCompletion(databaseBuildRequest) {
            didCommit = true
        }

        XCTAssertFalse(didCommit)
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

private func makeSidebarProjectFixture(prefix: String) throws -> (tempRoot: URL, projectURL: URL, fastaURL: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
    let fastaURL = projectURL.appendingPathComponent("example.fasta")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
    return (tempRoot, projectURL, fastaURL)
}
