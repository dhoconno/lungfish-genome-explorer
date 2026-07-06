// UniversalProjectSearchService.swift - App orchestration for project-scoped universal search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
public actor UniversalProjectSearchService {

    public static let shared = UniversalProjectSearchService()

    private var indexes: [URL: ProjectUniversalSearchIndex] = [:]
    private var scheduledRebuildTasks: [URL: Task<Void, Never>] = [:]
    private var hasIndexedOnce: Set<URL> = []

    public init() {}

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
        let startedAt = Date()
        let stats = try index.rebuild()
        try writeIndexProvenance(
            projectURL: canonical,
            index: index,
            operation: "rebuild",
            stats: stats,
            startedAt: startedAt
        )
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
                let startedAt = Date()
                let buildStats = try index.rebuild()
                try writeIndexProvenance(
                    projectURL: canonical,
                    index: index,
                    operation: "build-on-demand",
                    stats: buildStats,
                    startedAt: startedAt,
                    explicitOptions: [
                        "query": .string(query),
                        "limit": .integer(max(1, limit)),
                    ]
                )
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
            let startedAt = Date()
            try idx.update(changedPaths: changedPaths)
            try writeIndexProvenance(
                projectURL: canonical,
                index: idx,
                operation: "update",
                stats: nil,
                startedAt: startedAt,
                explicitOptions: [
                    "changedPathCount": .integer(changedPaths.count),
                    "changedPaths": .array(changedPaths.map { .string($0.standardizedFileURL.path) }),
                ]
            )
        } catch {
            universalSearchLogger.error(
                "update(changedPaths:) failed for \(canonical.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Clears cached state for a project (used when closing/changing projects).
    public func clearProject(_ projectURL: URL) {
        let canonical = projectURL.standardizedFileURL
        scheduledRebuildTasks[canonical]?.cancel()
        scheduledRebuildTasks.removeValue(forKey: canonical)
        indexes.removeValue(forKey: canonical)
        hasIndexedOnce.remove(canonical)
    }

    private func index(for projectURL: URL) throws -> ProjectUniversalSearchIndex {
        if let existing = indexes[projectURL] {
            return existing
        }

        let created = try ProjectUniversalSearchIndex(projectURL: projectURL)
        indexes[projectURL] = created
        return created
    }

    private func writeIndexProvenance(
        projectURL: URL,
        index: ProjectUniversalSearchIndex,
        operation: String,
        stats: ProjectUniversalSearchBuildStats?,
        startedAt: Date,
        explicitOptions: [String: ParameterValue] = [:]
    ) throws {
        try UniversalSearchIndexProvenanceWriter.write(
            UniversalSearchIndexProvenanceRequest(
                workflowName: "lungfish app universal-search",
                toolName: "Lungfish.app universal-search",
                toolKind: "gui",
                projectURL: projectURL,
                databaseURL: index.databaseURL,
                operation: operation,
                argv: ["Lungfish.app", "universal-search", operation, projectURL.path],
                explicitOptions: explicitOptions,
                defaults: [:],
                resolvedDefaults: ["operation": .string(operation)],
                buildStats: stats,
                startedAt: startedAt,
                completedAt: Date()
            )
        )
    }
}
