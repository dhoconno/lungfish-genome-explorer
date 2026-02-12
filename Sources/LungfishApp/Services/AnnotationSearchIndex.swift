// AnnotationSearchIndex.swift - In-memory annotation name index for search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation search operations
private let searchLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationSearch")

// MARK: - AnnotationSearchIndex

/// Annotation index that provides fast text search and filtering.
///
/// Search is backed by SQLite annotation/variant databases in the bundle.
@MainActor
public final class AnnotationSearchIndex {

    // MARK: - Types

    /// A search result representing a single annotation or variant feature.
    public struct SearchResult: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let chromosome: String
        public let start: Int
        public let end: Int
        public let trackId: String
        public let type: String
        public let strand: String

        // Variant-specific fields (nil for annotations)
        public let ref: String?
        public let alt: String?
        public let quality: Double?
        public let filter: String?
        public let sampleCount: Int?
        public let variantRowId: Int64?

        /// Whether this result represents a variant (vs annotation).
        public var isVariant: Bool { ref != nil }

        public init(id: UUID = UUID(), name: String, chromosome: String, start: Int, end: Int,
                    trackId: String, type: String = "gene", strand: String = ".",
                    ref: String? = nil, alt: String? = nil, quality: Double? = nil,
                    filter: String? = nil, sampleCount: Int? = nil, variantRowId: Int64? = nil) {
            self.id = id
            self.name = name
            self.chromosome = chromosome
            self.start = start
            self.end = end
            self.trackId = trackId
            self.type = type
            self.strand = strand
            self.ref = ref
            self.alt = alt
            self.quality = quality
            self.filter = filter
            self.sampleCount = sampleCount
            self.variantRowId = variantRowId
        }
    }

    // MARK: - Properties

    /// In-memory entries used when SQLite mode is unavailable.
    private var entries: [SearchResult] = []

    /// SQLite database handle (preferred mode).
    private var database: AnnotationDatabase?

    /// Variant SQLite database handle (for unified search).
    private var variantDatabases: [(trackId: String, db: VariantDatabase)] = []

    /// Track ID associated with the database (for SearchResult compatibility).
    private var databaseTrackId: String = ""

    /// Whether the index is currently being built.
    public private(set) var isBuilding: Bool = false

    /// Whether this index is backed by SQLite (vs in-memory).
    public var hasDatabaseBackend: Bool { database != nil }

    /// Provides access to the underlying annotation database for enrichment lookups.
    public var annotationDatabase: AnnotationDatabase? { database }

    /// Number of indexed entries.
    public var entryCount: Int {
        if let db = database {
            return db.totalCount()
        }
        return entries.count
    }

    /// All indexed entries (for populating the annotation table drawer).
    /// For SQLite mode, returns up to the display limit.
    public var allResults: [SearchResult] {
        if let db = database {
            let records = db.query(limit: 5000)
            return records.map { record in
                SearchResult(
                    name: record.name,
                    chromosome: record.chromosome,
                    start: record.start,
                    end: record.end,
                    trackId: databaseTrackId,
                    type: record.type,
                    strand: record.strand
                )
            }
        }
        return entries
    }

    /// All distinct annotation types in the index (includes variant types).
    public var allTypes: [String] {
        var types: Set<String>
        if let db = database {
            types = Set(db.allTypes())
        } else {
            types = Set(entries.map { $0.type })
        }
        for handle in variantDatabases {
            types.formUnion(handle.db.allTypes())
        }
        return types.sorted()
    }

    /// Callback invoked on the main thread when index building completes.
    public var onBuildComplete: (() -> Void)?

    // MARK: - SQLite Mode

    /// Builds the index from a SQLite database file in the bundle.
    /// This is instant — no background scanning needed.
    ///
    /// - Parameters:
    ///   - bundle: The reference bundle containing annotation tracks
    ///   - trackId: The annotation track ID that has the database
    ///   - databasePath: Relative path to the .db file within the bundle
    /// - Returns: true if the database was opened successfully
    @discardableResult
    public func buildFromDatabase(bundle: ReferenceBundle, trackId: String, databasePath: String) -> Bool {
        let dbURL = bundle.url.appendingPathComponent(databasePath)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            searchLogger.warning("AnnotationSearchIndex: Database not found at \(databasePath)")
            return false
        }

        do {
            database = try AnnotationDatabase(url: dbURL)
            databaseTrackId = trackId
            isBuilding = false
            let count = database?.totalCount() ?? 0
            searchLogger.info("AnnotationSearchIndex: Opened SQLite database with \(count) annotations")

            // Also open variant databases if available
            openVariantDatabases(bundle: bundle)

            onBuildComplete?()
            return true
        } catch {
            searchLogger.error("AnnotationSearchIndex: Failed to open database: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens variant databases from the bundle for unified search.
    private func openVariantDatabases(bundle: ReferenceBundle) {
        variantDatabases.removeAll()
        for vTrackId in bundle.variantTrackIds {
            guard let trackInfo = bundle.variantTrack(id: vTrackId),
                  let dbPath = trackInfo.databasePath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            do {
                let db = try VariantDatabase(url: dbURL)
                variantDatabases.append((trackId: vTrackId, db: db))
                let vcount = db.totalCount()
                searchLogger.info("AnnotationSearchIndex: Opened variant database '\(vTrackId, privacy: .public)' with \(vcount) variants")
            } catch {
                searchLogger.warning("AnnotationSearchIndex: Failed to open variant database '\(vTrackId, privacy: .public)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Index Build

    /// Builds the index from a bundle annotation database.
    ///
    /// Bundles are expected to provide SQLite annotation tracks.
    ///
    /// - Parameters:
    ///   - bundle: The reference bundle containing annotation tracks
    ///   - chromosomes: The chromosome list to scan
    public func buildIndex(bundle: ReferenceBundle, chromosomes: [ChromosomeInfo]) {
        _ = chromosomes

        for trackId in bundle.annotationTrackIds {
            if let trackInfo = bundle.annotationTrack(id: trackId),
               let dbPath = trackInfo.databasePath {
                if buildFromDatabase(bundle: bundle, trackId: trackId, databasePath: dbPath) {
                    return
                }
            }
        }

        // Open variant databases even if there are no annotation databases.
        openVariantDatabases(bundle: bundle)
        entries = []
        isBuilding = false
        searchLogger.warning("AnnotationSearchIndex: No annotation SQLite database found; annotation search will be empty")
        onBuildComplete?()
    }

    /// Searches the index for annotations matching the query.
    ///
    /// Performs case-insensitive substring matching on annotation names.
    ///
    /// - Parameters:
    ///   - query: The search text
    ///   - limit: Maximum number of results to return (default 20)
    /// - Returns: Array of matching search results
    public func search(query: String, limit: Int = 20) -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        var results: [SearchResult] = []

        if let db = database {
            let records = db.query(nameFilter: query, limit: limit)
            results = records.map { record in
                SearchResult(
                    name: record.name,
                    chromosome: record.chromosome,
                    start: record.start,
                    end: record.end,
                    trackId: databaseTrackId,
                    type: record.type,
                    strand: record.strand
                )
            }
        } else {
            // Legacy in-memory search
            let lowered = query.lowercased()

            // Prioritize exact prefix matches, then contains matches
            for entry in entries {
                if entry.name.lowercased().hasPrefix(lowered) {
                    results.append(entry)
                    if results.count >= limit { return results }
                }
            }

            for entry in entries {
                if !entry.name.lowercased().hasPrefix(lowered),
                   entry.name.lowercased().contains(lowered) {
                    results.append(entry)
                    if results.count >= limit { return results }
                }
            }
        }

        // Also search variant database
        if results.count < limit {
            for handle in variantDatabases {
                let remaining = limit - results.count
                guard remaining > 0 else { break }
                let variantRecords = handle.db.searchByID(idFilter: query, limit: remaining)
                results.append(contentsOf: variantRecords.map { $0.toSearchResult(trackId: handle.trackId) })
            }
        }

        return results
    }

    /// Queries the index with both name and type filters.
    /// Only available in SQLite mode — returns nil when no annotation database is open.
    ///
    /// - Parameters:
    ///   - nameFilter: Case-insensitive substring match on name
    ///   - types: Set of type strings to include (empty = all)
    ///   - limit: Maximum results
    /// - Returns: Array of matching results, or nil if not in SQLite mode
    public func query(nameFilter: String = "", types: Set<String> = [], limit: Int = 5000) -> [SearchResult]? {
        guard let db = database else { return nil }
        let records = db.query(nameFilter: nameFilter, types: types, limit: limit)
        return records.map { record in
            SearchResult(
                name: record.name,
                chromosome: record.chromosome,
                start: record.start,
                end: record.end,
                trackId: databaseTrackId,
                type: record.type,
                strand: record.strand
            )
        }
    }

    /// Returns the count of annotations matching filters (SQLite mode only).
    public func queryCount(nameFilter: String = "", types: Set<String> = []) -> Int? {
        guard let db = database else { return nil }
        var count = db.queryCount(nameFilter: nameFilter, types: types)

        // Add variant counts if variant database is available and types match
        for handle in variantDatabases {
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            if !requestedVariantTypes.isEmpty || types.isEmpty {
                count += handle.db.queryCountForTable(nameFilter: nameFilter, types: requestedVariantTypes)
            }
        }

        return count
    }

    /// Queries both annotation and variant databases with unified filters.
    /// Returns combined results from both databases, with variants appended after annotations.
    public func queryAll(nameFilter: String = "", types: Set<String> = [], limit: Int = 5000) -> [SearchResult] {
        var results: [SearchResult] = []

        // Query annotation database
        if let annotationResults = query(nameFilter: nameFilter, types: types, limit: limit) {
            results.append(contentsOf: annotationResults)
        }

        // Query variant database
        if results.count < limit {
            for handle in variantDatabases {
                let remaining = limit - results.count
                guard remaining > 0 else { break }
                let variantTypes = Set(handle.db.allTypes())
                let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
                guard !requestedVariantTypes.isEmpty || types.isEmpty else { continue }
                let variantRecords = handle.db.queryForTable(
                    nameFilter: nameFilter,
                    types: types.isEmpty ? [] : requestedVariantTypes,
                    limit: remaining
                )
                results.append(contentsOf: variantRecords.map { $0.toSearchResult(trackId: handle.trackId) })
            }
        }

        return results
    }

    /// Queries ONLY annotations (no variants). Used when the Annotations tab is active.
    public func queryAnnotationsOnly(nameFilter: String = "", types: Set<String> = [], limit: Int = 5000) -> [SearchResult] {
        query(nameFilter: nameFilter, types: types, limit: limit) ?? []
    }

    /// Returns count of annotations only (no variants).
    public func queryAnnotationCount(nameFilter: String = "", types: Set<String> = []) -> Int {
        guard let db = database else { return 0 }
        return db.queryCount(nameFilter: nameFilter, types: types)
    }

    /// Queries ONLY variants (no annotations). Used when the Variants tab is active.
    public func queryVariantsOnly(nameFilter: String = "", types: Set<String> = [], limit: Int = 5000) -> [SearchResult] {
        var results: [SearchResult] = []
        for handle in variantDatabases {
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            guard !requestedVariantTypes.isEmpty || types.isEmpty else { continue }
            let variantRecords = handle.db.queryForTable(
                nameFilter: nameFilter,
                types: types.isEmpty ? [] : requestedVariantTypes,
                limit: remaining
            )
            results.append(contentsOf: variantRecords.map { $0.toSearchResult(trackId: handle.trackId) })
        }
        return results
    }

    /// Returns count of variants only (no annotations).
    public func queryVariantCount(nameFilter: String = "", types: Set<String> = []) -> Int {
        var count = 0
        for handle in variantDatabases {
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            if !requestedVariantTypes.isEmpty || types.isEmpty {
                count += handle.db.queryCountForTable(nameFilter: nameFilter, types: requestedVariantTypes)
            }
        }
        return count
    }

    /// All distinct annotation types only (no variant types).
    public var annotationTypes: [String] {
        if let db = database {
            return db.allTypes().sorted()
        }
        return Set(entries.map { $0.type }).sorted()
    }

    /// Whether a variant database is available for unified queries.
    public var hasVariantDatabase: Bool { !variantDatabases.isEmpty }

    /// All distinct variant types (separate from annotation types).
    public var variantTypes: [String] {
        var all: Set<String> = []
        for handle in variantDatabases {
            all.formUnion(handle.db.allTypes())
        }
        return all.sorted()
    }

    /// Total variant count.
    public var variantCount: Int {
        variantDatabases.reduce(0) { $0 + $1.db.totalCount() }
    }

    /// Clears the index.
    public func clear() {
        entries = []
        database = nil
        variantDatabases = []
        isBuilding = false
    }
}

// MARK: - VariantDatabaseRecord → SearchResult Conversion

extension VariantDatabaseRecord {
    /// Converts this variant record to an `AnnotationSearchIndex.SearchResult`
    /// for unified display in the annotation table drawer.
    public func toSearchResult(trackId: String = "variants") -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: variantID,
            chromosome: chromosome,
            start: position,
            end: end,
            trackId: trackId,
            type: variantType,
            strand: ".",
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            sampleCount: sampleCount,
            variantRowId: id
        )
    }
}
