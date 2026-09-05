import Foundation
import LungfishCore

@MainActor
public final class ProjectFilesystemRefreshCoordinator {
    public typealias SubscriptionID = UUID
    public typealias Handler = @MainActor (FileSystemWatcher.ChangedPaths) -> Void
    public typealias EventHandler = @MainActor (Event) -> Void

    public enum Event: Sendable {
        case changed(FileSystemWatcher.ChangedPaths)
        case unavailable(reason: String)
        case rebound(URL)
    }

    public static let shared = ProjectFilesystemRefreshCoordinator()

    /// Continuity evidence only; native format and write access are revalidated
    /// by the existing project-open path after a successful filesystem rebind.
    struct RootIdentity: Equatable, Sendable {
        let volume: String
        let fileNumber: UInt64
        let createdAt: Date
    }

    private final class ProjectWatcher {
        var projectURL: URL
        let watcher: FileSystemWatcher
        var handlers: [SubscriptionID: EventHandler] = [:]
        var unavailableReason: String?
        var identity: RootIdentity?
        var identityTask: Task<Void, Never>?
        var pendingFullReloadTask: Task<Void, Never>?
        var recoveryGeneration = UUID()

        init(projectURL: URL, watcher: FileSystemWatcher) {
            self.projectURL = projectURL
            self.watcher = watcher
        }
    }

    private struct SubscriptionRecord { let projectKey: String }
    private var watchersByProjectKey: [String: ProjectWatcher] = [:]
    private var subscriptionsByID: [SubscriptionID: SubscriptionRecord] = [:]
    private var fullReloadDebounce: Duration = .milliseconds(500)
    private let readIdentity: @Sendable (URL) throws -> RootIdentity

    public init() { readIdentity = Self.rootIdentity }
    init(readIdentity: @escaping @Sendable (URL) throws -> RootIdentity) { self.readIdentity = readIdentity }

    @discardableResult
    public func register(projectURL: URL, handler: @escaping Handler) -> SubscriptionID {
        registerEvents(projectURL: projectURL) { event in
            if case .changed(let paths) = event { handler(paths) }
        }
    }

    @discardableResult
    public func registerEvents(projectURL: URL, handler: @escaping EventHandler) -> SubscriptionID {
        let canonicalURL = Self.canonicalProjectURL(projectURL)
        let key = canonicalURL.path
        let id = SubscriptionID()
        let entry: ProjectWatcher
        if let existing = watchersByProjectKey[key] {
            entry = existing
        } else {
            let incarnation = UUID()
            let watcher = FileSystemWatcher(
                onChange: { [weak self] paths in self?.fanOut(projectKey: key, callbackID: incarnation, changedPaths: paths) },
                onRootChanged: { [weak self] in self?.markUnavailable(projectKey: key, callbackID: incarnation, reason: "Project folder moved or its volume disconnected.") },
                onUnavailable: { [weak self] reason in self?.markUnavailable(projectKey: key, callbackID: incarnation, reason: reason) }
            )
            entry = ProjectWatcher(projectURL: canonicalURL, watcher: watcher)
            callbackIDs[key] = incarnation
            watchersByProjectKey[key] = entry
            let read = readIdentity
            entry.identityTask = Task { @MainActor [weak self, weak entry] in
                let identity = try? await Task.detached(priority: .utility) { try read(canonicalURL) }.value
                guard let self, let entry, self.watchersByProjectKey[key] === entry,
                      entry.unavailableReason == nil else { return }
                entry.identity = identity
                if identity == nil {
                    self.markUnavailable(projectKey: key, reason: "Project folder is unavailable or its identity cannot be verified.")
                }
            }
            watcher.startWatching(directory: canonicalURL)
        }
        entry.handlers[id] = handler
        subscriptionsByID[id] = SubscriptionRecord(projectKey: key)
        if let reason = entry.unavailableReason { handler(.unavailable(reason: reason)) }
        return id
    }

    // A callback belongs to one entry incarnation, even if that path is reused.
    private var callbackIDs: [String: UUID] = [:]

    public func unregister(_ subscriptionID: SubscriptionID?) {
        guard let subscriptionID, let record = subscriptionsByID.removeValue(forKey: subscriptionID),
              let entry = watchersByProjectKey[record.projectKey] else { return }
        entry.handlers.removeValue(forKey: subscriptionID)
        if entry.handlers.isEmpty {
            entry.pendingFullReloadTask?.cancel()
            entry.identityTask?.cancel()
            entry.watcher.stopWatching()
            watchersByProjectKey.removeValue(forKey: record.projectKey)
            callbackIDs.removeValue(forKey: record.projectKey)
        }
    }

    public func unregisterAll() {
        for entry in watchersByProjectKey.values {
            entry.pendingFullReloadTask?.cancel()
            entry.identityTask?.cancel()
            entry.watcher.stopWatching()
        }
        watchersByProjectKey.removeAll()
        subscriptionsByID.removeAll()
        callbackIDs.removeAll()
    }

    /// Explicit Retry/Locate. Merely recreating a directory at the same path is
    /// insufficient; the original volume and directory identity must match.
    @discardableResult
    public func rebind(_ subscriptionID: SubscriptionID, to candidateURL: URL? = nil) async -> Bool {
        guard let record = subscriptionsByID[subscriptionID], let entry = watchersByProjectKey[record.projectKey] else { return false }
        await entry.identityTask?.value
        guard let expected = entry.identity else {
            markUnavailable(projectKey: record.projectKey, reason: "Original folder identity is unavailable. Close all windows for this project before opening the location as a new project.")
            return false
        }
        let candidate = candidateURL ?? entry.projectURL
        let recovery = UUID()
        entry.recoveryGeneration = recovery
        let read = readIdentity
        let observed = try? await Task.detached(priority: .utility) { try read(candidate) }.value
        guard !Task.isCancelled, watchersByProjectKey[record.projectKey] === entry,
              subscriptionsByID[subscriptionID]?.projectKey == record.projectKey,
              entry.recoveryGeneration == recovery else { return false }
        guard observed == expected else {
            markUnavailable(projectKey: record.projectKey,
                reason: "Folder is missing, inaccessible, or is a replacement. Locate the original folder, or close all old project windows before opening a replacement.")
            return false
        }
        entry.projectURL = Self.canonicalProjectURL(candidate)
        entry.unavailableReason = nil
        entry.watcher.startWatching(directory: entry.projectURL)
        for handler in Array(entry.handlers.values) { handler(.rebound(entry.projectURL)) }
        return true
    }

    func validatedIdentity(for subscriptionID: SubscriptionID) -> RootIdentity? {
        guard let record = subscriptionsByID[subscriptionID] else { return nil }
        return watchersByProjectKey[record.projectKey]?.identity
    }

    func invalidate(_ subscriptionID: SubscriptionID, reason: String) {
        guard let record = subscriptionsByID[subscriptionID] else { return }
        markUnavailable(projectKey: record.projectKey, reason: reason)
    }

    func isUnavailable(projectURL: URL) -> Bool {
        watchersByProjectKey[Self.canonicalProjectURL(projectURL).path]?.unavailableReason != nil
    }

    func testingWaitForIdentity(projectURL: URL) async {
        await watchersByProjectKey[Self.canonicalProjectURL(projectURL).path]?.identityTask?.value
    }
    func testingWatcherCount(for projectURL: URL) -> Int {
        guard let entry = watchersByProjectKey[Self.canonicalProjectURL(projectURL).path] else { return 0 }
        return entry.unavailableReason == nil ? 1 : 0
    }
    func testingSubscriberCount(for projectURL: URL) -> Int {
        watchersByProjectKey[Self.canonicalProjectURL(projectURL).path]?.handlers.count ?? 0
    }
    func testingEmitChange(projectURL: URL, changedPaths: FileSystemWatcher.ChangedPaths) {
        fanOut(projectKey: Self.canonicalProjectURL(projectURL).path, changedPaths: changedPaths)
    }
    func testingSimulateRootChanged(projectURL: URL) {
        markUnavailable(projectKey: Self.canonicalProjectURL(projectURL).path, reason: "Project folder moved or its volume disconnected.")
    }
    func testingSetFullReloadDebounce(_ duration: Duration) { fullReloadDebounce = duration }

    private func fanOut(projectKey: String, callbackID: UUID? = nil, changedPaths: FileSystemWatcher.ChangedPaths) {
        guard callbackID == nil || callbackIDs[projectKey] == callbackID,
              let entry = watchersByProjectKey[projectKey], entry.unavailableReason == nil else { return }
        if changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty {
            entry.pendingFullReloadTask?.cancel()
            let delay = fullReloadDebounce
            entry.pendingFullReloadTask = Task { @MainActor [weak self, weak entry] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, let entry, self.watchersByProjectKey[projectKey] === entry,
                      entry.unavailableReason == nil, !Task.isCancelled else { return }
                entry.pendingFullReloadTask = nil
                for handler in Array(entry.handlers.values) { handler(.changed(changedPaths)) }
            }
            return
        }
        guard entry.pendingFullReloadTask == nil else { return }
        for handler in Array(entry.handlers.values) { handler(.changed(changedPaths)) }
    }

    private func markUnavailable(projectKey: String, callbackID: UUID? = nil, reason: String) {
        guard callbackID == nil || callbackIDs[projectKey] == callbackID,
              let entry = watchersByProjectKey[projectKey] else { return }
        entry.pendingFullReloadTask?.cancel()
        entry.pendingFullReloadTask = nil
        entry.recoveryGeneration = UUID()
        entry.watcher.stopWatching()
        guard entry.unavailableReason != reason else { return }
        entry.unavailableReason = reason
        for handler in Array(entry.handlers.values) { handler(.unavailable(reason: reason)) }
    }

    nonisolated static func rootIdentity(at url: URL) throws -> RootIdentity {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isReadableFile(atPath: canonical.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        let volume = try? canonical.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return RootIdentity(volume: volume ?? "device:\(device.uint64Value)", fileNumber: file.uint64Value, createdAt: created)
    }

    private static func canonicalProjectURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}
