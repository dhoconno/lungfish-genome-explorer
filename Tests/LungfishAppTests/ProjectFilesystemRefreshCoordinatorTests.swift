import XCTest
@testable import LungfishApp

@MainActor
final class ProjectFilesystemRefreshCoordinatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFilesystemRefreshCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ProjectFilesystemRefreshCoordinator.shared.testingSetFullReloadDebounce(.milliseconds(50))
    }

    override func tearDown() async throws {
        ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
        ProjectFilesystemRefreshCoordinator.shared.testingSetFullReloadDebounce(.milliseconds(500))
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    func testDuplicateProjectSubscriptionsShareOneWatcherAndFanOutChanges() throws {
        let projectURL = tempRoot.appendingPathComponent("Shared.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var firstReceived = 0
        var secondReceived = 0

        let firstID = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in
            firstReceived += 1
        }
        let secondID = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in
            secondReceived += 1
        }

        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 1)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 2)

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(
                nonSidecar: [projectURL.appendingPathComponent("Analyses")],
                all: [projectURL.appendingPathComponent("Analyses")]
            )
        )

        XCTAssertEqual(firstReceived, 1)
        XCTAssertEqual(secondReceived, 1)

        ProjectFilesystemRefreshCoordinator.shared.unregister(firstID)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 1)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 1)

        ProjectFilesystemRefreshCoordinator.shared.unregister(secondID)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 0)
    }

    func testRootChangedRemovesDeadSharedWatcherAndSubscriptions() throws {
        let projectURL = tempRoot.appendingPathComponent("RootChanged.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in }
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 1)

        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: projectURL)

        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 0)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 0)

        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in }
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 1)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 1)
    }

    func testMustScanSubDirsChangesAreCoalescedIntoOneFullReload() async throws {
        let projectURL = tempRoot.appendingPathComponent("MustScanStorm.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var receivedFullReloads: [FileSystemWatcher.ChangedPaths] = []
        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { changedPaths in
            if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
                receivedFullReloads.append(changedPaths)
            }
        }

        let fullReload = FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)

        XCTAssertEqual(receivedFullReloads.count, 0, "Full reload events should be delayed so bursts can coalesce")

        try await waitForCoordinatorCondition {
            receivedFullReloads.count == 1
        }

        XCTAssertEqual(receivedFullReloads.count, 1)
        XCTAssertTrue(receivedFullReloads[0].nonSidecar.isEmpty)
        XCTAssertTrue(receivedFullReloads[0].all.isEmpty)
    }

    func testMustScanSubDirsDebounceIsTrailing() async throws {
        let projectURL = tempRoot.appendingPathComponent("MustScanTrailing.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var receivedFullReloads: [FileSystemWatcher.ChangedPaths] = []
        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { changedPaths in
            if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
                receivedFullReloads.append(changedPaths)
            }
        }

        let fullReload = FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)
        try await Task.sleep(for: .milliseconds(30))
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(receivedFullReloads.count, 0, "Second event should restart the full-reload debounce")

        try await waitForCoordinatorCondition {
            receivedFullReloads.count == 1
        }
        XCTAssertEqual(receivedFullReloads.count, 1)
    }

    func testPendingMustScanSubDirsReloadIsCancelledWhenSubscriptionIsRemoved() async throws {
        let projectURL = tempRoot.appendingPathComponent("MustScanCancel.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var receivedFullReloads: [FileSystemWatcher.ChangedPaths] = []
        let id = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { changedPaths in
            if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
                receivedFullReloads.append(changedPaths)
            }
        }

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
        )
        ProjectFilesystemRefreshCoordinator.shared.unregister(id)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(receivedFullReloads.count, 0)
    }
}

@MainActor
private func waitForCoordinatorCondition(
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
