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

    func testRootChangedStopsDeadWatcherButRetainsSubscriptionIntentForRecovery() throws {
        let projectURL = tempRoot.appendingPathComponent("RootChanged.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in }
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 1)

        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: projectURL)

        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingWatcherCount(for: projectURL), 0)
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 1,
            "A lost root must retain the window's subscription so it can deliver unavailable state and recover")

        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { _ in }
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: projectURL), 2)
    }

    func testRootLossRetainsBothWindowsUntilEachExplicitlyUnsubscribes() throws {
        let projectURL = tempRoot.appendingPathComponent("TwoWindows.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let coordinator = ProjectFilesystemRefreshCoordinator.shared
        let first = coordinator.register(projectURL: projectURL) { _ in }
        let second = coordinator.register(projectURL: projectURL) { _ in }
        coordinator.testingSimulateRootChanged(projectURL: projectURL)
        XCTAssertEqual(coordinator.testingSubscriberCount(for: projectURL), 2)
        coordinator.unregister(first)
        XCTAssertEqual(coordinator.testingSubscriberCount(for: projectURL), 1)
        coordinator.unregister(second)
        XCTAssertEqual(coordinator.testingSubscriberCount(for: projectURL), 0)
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

    func testUnavailableReachesBothWindowsAndRetryRecoversOriginalDirectory() async throws {
        let url = tempRoot.appendingPathComponent("Original")
        let moved = tempRoot.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let coordinator = ProjectFilesystemRefreshCoordinator()
        defer { coordinator.unregisterAll() }
        var first: [String] = []
        var second: [String] = []
        let id = coordinator.registerEvents(projectURL: url) { first.append(Self.eventName($0)) }
        _ = coordinator.registerEvents(projectURL: url) { second.append(Self.eventName($0)) }
        await coordinator.testingWaitForIdentity(projectURL: url)
        try FileManager.default.moveItem(at: url, to: moved)
        coordinator.testingSimulateRootChanged(projectURL: url)
        coordinator.testingSimulateRootChanged(projectURL: url)
        coordinator.testingEmitChange(projectURL: url, changedPaths: .init(nonSidecar: [url], all: [url]))
        XCTAssertEqual(first, ["unavailable"])
        XCTAssertEqual(second, ["unavailable"])
        try FileManager.default.moveItem(at: moved, to: url)
        let recovered = await coordinator.rebind(id)
        XCTAssertTrue(recovered)
        XCTAssertEqual(first, ["unavailable", "rebound"])
        XCTAssertEqual(second, ["unavailable", "rebound"])
    }

    func testLocateRejectsReplacementAndRecoversSameMovedDirectory() async throws {
        let url = tempRoot.appendingPathComponent("Original")
        let moved = tempRoot.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let coordinator = ProjectFilesystemRefreshCoordinator()
        defer { coordinator.unregisterAll() }
        var rebound: URL?
        let id = coordinator.registerEvents(projectURL: url) { if case .rebound(let value) = $0 { rebound = value } }
        await coordinator.testingWaitForIdentity(projectURL: url)
        try FileManager.default.moveItem(at: url, to: moved)
        coordinator.testingSimulateRootChanged(projectURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let replaced = await coordinator.rebind(id)
        XCTAssertFalse(replaced)
        XCTAssertNil(rebound)
        let located = await coordinator.rebind(id, to: moved)
        XCTAssertTrue(located)
        XCTAssertEqual(rebound?.path, moved.path)
    }

    func testSupersededRecoveryCannotRebindNewSubscriptionAtSamePath() async throws {
        let url = tempRoot.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let started = expectation(description: "revalidation suspended")
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let calls = FilesystemIdentityCallCounter()
        let coordinator = ProjectFilesystemRefreshCoordinator(readIdentity: { url in
            let identity = try ProjectFilesystemRefreshCoordinator.rootIdentity(at: url)
            if calls.next() == 2 { started.fulfill(); _ = finish.wait(timeout: .now() + 10) }
            return identity
        })
        defer { coordinator.unregisterAll() }
        let old = coordinator.registerEvents(projectURL: url) { _ in }
        await coordinator.testingWaitForIdentity(projectURL: url)
        coordinator.testingSimulateRootChanged(projectURL: url)
        let recovery = Task { await coordinator.rebind(old) }
        await fulfillment(of: [started], timeout: 3)
        coordinator.unregister(old)
        var newEvents: [String] = []
        _ = coordinator.registerEvents(projectURL: url) { newEvents.append(Self.eventName($0)) }
        await coordinator.testingWaitForIdentity(projectURL: url)
        finish.signal()
        let result = await recovery.value
        XCTAssertFalse(result)
        XCTAssertTrue(newEvents.isEmpty)
        XCTAssertEqual(coordinator.testingSubscriberCount(for: url), 1)
    }

    private static func eventName(_ event: ProjectFilesystemRefreshCoordinator.Event) -> String {
        switch event { case .changed: "changed"; case .unavailable: "unavailable"; case .rebound: "rebound" }
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

    func testPendingMustScanSubDirsCoalescesFollowingConcreteChangesIntoOneFullReload() async throws {
        let projectURL = tempRoot.appendingPathComponent("MustScanMixedBurst.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var receivedChanges: [FileSystemWatcher.ChangedPaths] = []
        _ = ProjectFilesystemRefreshCoordinator.shared.register(projectURL: projectURL) { changedPaths in
            receivedChanges.append(changedPaths)
        }

        let fullReload = FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
        let concreteChange = FileSystemWatcher.ChangedPaths(
            nonSidecar: [projectURL.appendingPathComponent("Analyses")],
            all: [projectURL.appendingPathComponent("Analyses")]
        )

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: fullReload)
        try await Task.sleep(for: .milliseconds(20))
        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(projectURL: projectURL, changedPaths: concreteChange)

        XCTAssertEqual(receivedChanges.count, 0, "A concrete event during a pending full reload should not trigger an extra immediate reload")

        try await waitForCoordinatorCondition {
            receivedChanges.count == 1
        }

        XCTAssertEqual(receivedChanges.count, 1)
        XCTAssertTrue(receivedChanges[0].nonSidecar.isEmpty)
        XCTAssertTrue(receivedChanges[0].all.isEmpty)
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

private final class FilesystemIdentityCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
