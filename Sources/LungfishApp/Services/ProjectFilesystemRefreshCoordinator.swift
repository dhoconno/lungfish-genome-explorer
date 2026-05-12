import Foundation
import LungfishCore

@MainActor
public final class ProjectFilesystemRefreshCoordinator {
    public typealias SubscriptionID = UUID
    public typealias Handler = @MainActor (FileSystemWatcher.ChangedPaths) -> Void

    public static let shared = ProjectFilesystemRefreshCoordinator()

    private final class ProjectWatcher {
        let projectURL: URL
        let watcher: FileSystemWatcher
        var handlers: [SubscriptionID: Handler] = [:]

        init(projectURL: URL, watcher: FileSystemWatcher) {
            self.projectURL = projectURL
            self.watcher = watcher
        }
    }

    private struct SubscriptionRecord {
        let projectKey: String
    }

    private var watchersByProjectKey: [String: ProjectWatcher] = [:]
    private var subscriptionsByID: [SubscriptionID: SubscriptionRecord] = [:]

    public init() {}

    @discardableResult
    public func register(projectURL: URL, handler: @escaping Handler) -> SubscriptionID {
        let canonicalURL = Self.canonicalProjectURL(projectURL)
        let projectKey = canonicalURL.path
        let id = SubscriptionID()

        let projectWatcher: ProjectWatcher
        if let existing = watchersByProjectKey[projectKey] {
            projectWatcher = existing
        } else {
            let watcher = FileSystemWatcher(
                onChange: { [weak self] changedPaths in
                    self?.fanOut(projectKey: projectKey, changedPaths: changedPaths)
                },
                onRootChanged: { [weak self] in
                    self?.removeWatcher(projectKey: projectKey)
                }
            )
            projectWatcher = ProjectWatcher(projectURL: canonicalURL, watcher: watcher)
            watchersByProjectKey[projectKey] = projectWatcher
            watcher.startWatching(directory: canonicalURL)
        }

        projectWatcher.handlers[id] = handler
        subscriptionsByID[id] = SubscriptionRecord(projectKey: projectKey)
        return id
    }

    public func unregister(_ subscriptionID: SubscriptionID?) {
        guard let subscriptionID,
              let record = subscriptionsByID.removeValue(forKey: subscriptionID),
              let projectWatcher = watchersByProjectKey[record.projectKey] else {
            return
        }

        projectWatcher.handlers.removeValue(forKey: subscriptionID)
        if projectWatcher.handlers.isEmpty {
            projectWatcher.watcher.stopWatching()
            watchersByProjectKey.removeValue(forKey: record.projectKey)
        }
    }

    public func unregisterAll() {
        for projectWatcher in watchersByProjectKey.values {
            projectWatcher.watcher.stopWatching()
        }
        watchersByProjectKey.removeAll()
        subscriptionsByID.removeAll()
    }

    func testingWatcherCount(for projectURL: URL) -> Int {
        watchersByProjectKey[Self.canonicalProjectURL(projectURL).path] == nil ? 0 : 1
    }

    func testingSubscriberCount(for projectURL: URL) -> Int {
        watchersByProjectKey[Self.canonicalProjectURL(projectURL).path]?.handlers.count ?? 0
    }

    func testingEmitChange(projectURL: URL, changedPaths: FileSystemWatcher.ChangedPaths) {
        fanOut(projectKey: Self.canonicalProjectURL(projectURL).path, changedPaths: changedPaths)
    }

    func testingSimulateRootChanged(projectURL: URL) {
        removeWatcher(projectKey: Self.canonicalProjectURL(projectURL).path)
    }

    private func fanOut(projectKey: String, changedPaths: FileSystemWatcher.ChangedPaths) {
        guard let projectWatcher = watchersByProjectKey[projectKey] else { return }
        for handler in projectWatcher.handlers.values {
            handler(changedPaths)
        }
    }

    private func removeWatcher(projectKey: String) {
        guard let projectWatcher = watchersByProjectKey.removeValue(forKey: projectKey) else { return }
        projectWatcher.watcher.stopWatching()
        for subscriptionID in projectWatcher.handlers.keys {
            subscriptionsByID.removeValue(forKey: subscriptionID)
        }
    }

    private static func canonicalProjectURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
