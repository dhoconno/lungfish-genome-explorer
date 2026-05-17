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
    }

    override func tearDown() async throws {
        ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
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
}
