// AnnotationTableDrawerView+AnnotationQueryContext.swift - The cancellation token, the scope metadata gate and AnnotationQueryContext of the annotation drawer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

// MARK: - Background Variant Query Helpers

final class VariantQueryCancellationToken: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

#if DEBUG
final class AnnotationScopeMetadataQueryGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        release.wait()
    }

    func waitUntilPaused(timeout: DispatchTime = .now() + 2) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func resume() {
        release.signal()
    }
}
#endif

/// Snapshot of annotation database state needed for background annotation-table queries.
/// Stores database URLs, not live handles, so each background query uses its own
/// read-only SQLite connection instead of sharing the main actor's NOMUTEX handle.
struct AnnotationQueryContext: @unchecked Sendable {
    let databases: [(trackId: String, databaseURL: URL)]
    let trackNames: [String: String]
    let allowedChromosomes: Set<String>?

    init(
        databases: [(trackId: String, databaseURL: URL)],
        trackNames: [String: String],
        allowedChromosomes: Set<String>? = nil
    ) {
        self.databases = databases
        self.trackNames = trackNames
        self.allowedChromosomes = allowedChromosomes
    }

    func totalCount(shouldCancel: (() -> Bool)? = nil) -> Int {
        guard allowedChromosomes?.isEmpty != true else { return 0 }
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else { continue }
            count += database.totalCount(allowedChromosomes: allowedChromosomes)
        }
        return count
    }

    func allTypes(shouldCancel: (() -> Bool)? = nil) -> [String] {
        guard allowedChromosomes?.isEmpty != true else { return [] }
        var types = Set<String>()
        for handle in databases {
            if shouldCancel?() == true { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else { continue }
            types.formUnion(database.allTypes(allowedChromosomes: allowedChromosomes))
        }
        return types.sorted()
    }

    func queryAnnotationsOnly(
        nameFilter: String = "",
        types: Set<String> = [],
        chromosome: String? = nil,
        regionStart: Int? = nil,
        regionEnd: Int? = nil,
        strand: String? = nil,
        columnFilters: [AnnotationDatabase.ColumnFilterClause] = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        let databaseColumnFilters = columnFilters.filter { !Self.isTrackColumnFilter($0.key) }
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            guard Self.annotationTrackMatchesFilters(
                trackId: handle.trackId,
                trackName: trackNames[handle.trackId],
                filters: columnFilters
            ) else { continue }
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else {
                continue
            }
            if shouldCancel?() == true { break }
            let records = database.queryForTable(
                nameFilter: nameFilter,
                types: types,
                chromosome: chromosome,
                regionStart: regionStart,
                regionEnd: regionEnd,
                strand: strand,
                columnFilters: databaseColumnFilters,
                allowedChromosomes: allowedChromosomes,
                limit: remaining
            )
            if shouldCancel?() == true { break }
            results.append(contentsOf: records.map { record in
                Self.searchResult(from: record, trackId: handle.trackId, trackName: trackNames[handle.trackId])
            })
        }
        return results
    }

    private static func searchResult(
        from record: AnnotationDatabaseRecord,
        trackId: String,
        trackName: String?
    ) -> AnnotationSearchIndex.SearchResult {
        let parsedAttributes = record.attributes.map(AnnotationDatabase.parseAttributes).flatMap { attributes in
            attributes.isEmpty ? nil : attributes
        }
        return AnnotationSearchIndex.SearchResult(
            name: record.name,
            chromosome: record.chromosome,
            start: record.start,
            end: record.end,
            trackId: trackId,
            trackName: trackName,
            type: record.type,
            strand: record.strand,
            attributes: parsedAttributes,
            annotationRowId: record.rowID
        )
    }

    private static func isTrackColumnFilter(_ key: String) -> Bool {
        key == "track_id" || key == "track_name"
    }

    private static func annotationTrackMatchesFilters(
        trackId: String,
        trackName: String?,
        filters: [AnnotationDatabase.ColumnFilterClause]
    ) -> Bool {
        filters.allSatisfy { filter in
            switch filter.key {
            case "track_id":
                return trackColumnMatches(actual: trackId, op: filter.op, expected: filter.value)
            case "track_name":
                return trackColumnMatches(actual: trackName ?? trackId, op: filter.op, expected: filter.value)
            default:
                return true
            }
        }
    }

    private static func trackColumnMatches(actual: String, op: String, expected: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        switch op {
        case "=":
            if normalizedExpected.isEmpty { return normalizedActual.isEmpty }
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) == .orderedSame
        case "!=":
            if normalizedExpected.isEmpty { return !normalizedActual.isEmpty }
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) != .orderedSame
        case "!~":
            if normalizedExpected.isEmpty { return true }
            return !normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
        case "^=":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.lowercased().hasPrefix(normalizedExpected.lowercased())
        case "$=":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.lowercased().hasSuffix(normalizedExpected.lowercased())
        default:
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
        }
    }
}
