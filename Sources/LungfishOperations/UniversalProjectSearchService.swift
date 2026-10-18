// UniversalProjectSearchService.swift - App orchestration for project-scoped universal search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let universalSearchLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "UniversalProjectSearchService"
)

/// Coordinates universal-search indexing and querying for project folders.
///
/// This actor serializes access to each per-project SQLite index, supports
/// debounced rebuild scheduling on filesystem changes, and exposes query APIs
/// used by the sidebar and debugging flows.
///
/// The index is a derived cache that opening a project builds again, so it
/// writes no provenance record (plan row S12). A record on every rebuild and every
/// incremental update rewrote a file beside the project each time the project opened or
/// a file changed. `lungfish-cli universal-search --reindex` is a command the user
/// runs, and it keeps its record.
public actor UniversalProjectSearchService {

    public static let shared = UniversalProjectSearchService()

    private var indexes: [URL: ProjectUniversalSearchIndex] = [:]
    private var scheduledRebuildTasks: [URL: Task<Void, Never>] = [:]
    private var scheduledUpdateTasks: [URL: Task<Void, Never>] = [:]
    private var pendingUpdatePaths: [URL: Set<URL>] = [:]
    private var hasIndexedOnce: Set<URL> = []

    /// Called after each incremental update with the project and the paths it covered, so a test
    /// can see the batches the debounce makes. The update leaves nothing else behind to read.
    private var onUpdate: (@Sendable (URL, [URL]) -> Void)?

    public init() {}

    /// Sets the observer of incremental updates.
    func setOnUpdate(_ observer: (@Sendable (URL, [URL]) -> Void)?) {
        onUpdate = observer
    }

    /// Schedules a debounced index rebuild for a project.
    ///
    /// Any pending scheduled rebuild for the same project is cancelled.
    public func scheduleRebuild(projectURL: URL, delaySeconds: TimeInterval = 0.75) {
        let canonical = projectURL.standardizedFileURL

        scheduledRebuildTasks[canonical]?.cancel()
        scheduledRebuildTasks[canonical] = Task {
            if delaySeconds > 0 {
                let nanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else { return }

            do {
                _ = try await self.rebuild(projectURL: canonical)
            } catch {
                universalSearchLogger.error(
                    "scheduleRebuild failed for \(canonical.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Performs an immediate full index rebuild.
    @discardableResult
    public func rebuild(projectURL: URL) async throws -> ProjectUniversalSearchBuildStats {
        let canonical = projectURL.standardizedFileURL
        let index = try index(for: canonical)
        let stats = try index.rebuild()
        hasIndexedOnce.insert(canonical)
        return stats
    }

    /// Executes a universal query scoped to the given project.
    ///
    /// If `ensureIndexed` is true, the index is built on-demand when empty.
    public func search(
        projectURL: URL,
        query: String,
        limit: Int = 200,
        ensureIndexed: Bool = true
    ) throws -> [ProjectUniversalSearchResult] {
        let canonical = projectURL.standardizedFileURL
        let index = try index(for: canonical)

        if ensureIndexed {
            let stats = try index.indexStats()
            if stats.entityCount == 0 && !hasIndexedOnce.contains(canonical) {
                _ = try index.rebuild()
                hasIndexedOnce.insert(canonical)
            }
        }

        return try index.search(rawQuery: query, limit: max(1, limit))
    }

    /// Returns current index stats for a project.
    public func indexStats(projectURL: URL) throws -> ProjectUniversalSearchIndexStats {
        let canonical = projectURL.standardizedFileURL
        let index = try index(for: canonical)
        return try index.indexStats()
    }

    /// Incrementally updates the search index for specific changed paths.
    public func update(projectURL: URL, changedPaths: [URL]) {
        let canonical = projectURL.standardizedFileURL

        do {
            let idx = try index(for: canonical)
            try idx.update(changedPaths: changedPaths)
            onUpdate?(canonical, changedPaths)
        } catch {
            universalSearchLogger.error(
                "update(changedPaths:) failed for \(canonical.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// True when a change at `url` cannot alter what the index stores, so it should start no update.
    ///
    /// Two kinds of file qualify. The index writes its own database files, which must never feed back
    /// into it. A bundle's app state file, such as the `.viewstate.json` that the viewer rewrites after
    /// every pan or zoom pause, holds nothing the index stores, and indexing a reference bundle decodes
    /// its whole manifest.
    public static func ignoresChange(at url: URL) -> Bool {
        FileSystemWatcher.isUniversalSearchInternalPath(url) || BundleKindRegistry.isAppStateFile(at: url)
    }

    /// Coalesces a burst of filesystem changes into one incremental update.
    public func scheduleUpdate(
        projectURL: URL,
        changedPaths: [URL],
        delaySeconds: TimeInterval = 0.25
    ) {
        let canonical = projectURL.standardizedFileURL
        let sourcePaths = changedPaths
            .map(\.standardizedFileURL)
            .filter {
                $0 != canonical && !Self.ignoresChange(at: $0)
            }
        guard !sourcePaths.isEmpty else { return }

        pendingUpdatePaths[canonical, default: []].formUnion(sourcePaths)
        scheduledUpdateTasks[canonical]?.cancel()
        scheduledUpdateTasks[canonical] = Task { [weak self] in
            if delaySeconds > 0 {
                let nanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await self?.flushScheduledUpdate(projectURL: canonical)
        }
    }

    /// Clears cached state for a project (used when closing/changing projects).
    public func clearProject(_ projectURL: URL) {
        let canonical = projectURL.standardizedFileURL
        scheduledRebuildTasks[canonical]?.cancel()
        scheduledRebuildTasks.removeValue(forKey: canonical)
        scheduledUpdateTasks[canonical]?.cancel()
        scheduledUpdateTasks.removeValue(forKey: canonical)
        pendingUpdatePaths.removeValue(forKey: canonical)
        indexes.removeValue(forKey: canonical)
        hasIndexedOnce.remove(canonical)
    }

    private func flushScheduledUpdate(projectURL: URL) {
        scheduledUpdateTasks.removeValue(forKey: projectURL)
        let changedPaths = Array(pendingUpdatePaths.removeValue(forKey: projectURL) ?? [])
            .sorted { $0.path < $1.path }
        guard !changedPaths.isEmpty else { return }
        update(projectURL: projectURL, changedPaths: changedPaths)
    }

    private func index(for projectURL: URL) throws -> ProjectUniversalSearchIndex {
        if let existing = indexes[projectURL] {
            return existing
        }

        let created = try ProjectUniversalSearchIndex(projectURL: projectURL)
        indexes[projectURL] = created
        return created
    }
}
