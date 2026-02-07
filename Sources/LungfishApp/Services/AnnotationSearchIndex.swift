// AnnotationSearchIndex.swift - In-memory annotation name index for search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation search operations
private let searchLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationSearch")

/// Annotation types to include in the search index table.
/// Sub-gene features (exons, CDS, UTR) are excluded because they balloon the count
/// from ~30K gene-level features to ~3M rows, making the table unusable.
private let indexableTypes: Set<String> = [
    "gene", "mRNA", "transcript", "region", "promoter", "enhancer",
    "primer", "primer_pair", "amplicon", "SNP", "variation",
    "restriction_site", "repeat_region", "origin_of_replication",
    "misc_feature", "silencer", "terminator", "polyA_signal",
]

// MARK: - AnnotationSearchIndex

/// Annotation index that provides fast text search and filtering.
///
/// Two modes of operation:
/// 1. **SQLite mode** (preferred): When the bundle contains a `.db` file, queries
///    go directly to SQLite. The table drawer gets results instantly — no background
///    scanning or in-memory arrays required.
/// 2. **Legacy mode** (fallback): For older bundles without a database, scans all
///    BigBed annotation tracks across all chromosomes on a background thread and
///    builds an in-memory index.
///
/// Only gene-level features (genes, mRNA, transcripts, etc.) are indexed.
/// Sub-gene features like exons, CDS, and UTRs are excluded to keep the table
/// responsive with ~30K entries instead of ~3M.
@MainActor
public final class AnnotationSearchIndex {

    // MARK: - Types

    /// A search result representing a single annotation feature.
    public struct SearchResult: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let chromosome: String
        public let start: Int
        public let end: Int
        public let trackId: String
        public let type: String
        public let strand: String

        public init(id: UUID = UUID(), name: String, chromosome: String, start: Int, end: Int,
                    trackId: String, type: String = "gene", strand: String = ".") {
            self.id = id
            self.name = name
            self.chromosome = chromosome
            self.start = start
            self.end = end
            self.trackId = trackId
            self.type = type
            self.strand = strand
        }
    }

    // MARK: - Properties

    /// In-memory entries (legacy mode only).
    private var entries: [SearchResult] = []

    /// SQLite database handle (preferred mode).
    private var database: AnnotationDatabase?

    /// Track ID associated with the database (for SearchResult compatibility).
    private var databaseTrackId: String = ""

    /// Whether the index is currently being built.
    public private(set) var isBuilding: Bool = false

    /// Whether this index is backed by SQLite (vs in-memory).
    public var hasDatabaseBackend: Bool { database != nil }

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

    /// All distinct annotation types in the index.
    public var allTypes: [String] {
        if let db = database {
            return db.allTypes()
        }
        return Array(Set(entries.map { $0.type })).sorted()
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
            onBuildComplete?()
            return true
        } catch {
            searchLogger.error("AnnotationSearchIndex: Failed to open database: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Legacy BigBed Scanning Mode

    /// Builds the index by scanning all annotation tracks across all chromosomes.
    ///
    /// The heavy BigBed I/O runs on a background thread to avoid blocking the UI.
    /// Only gene-level features are indexed (exons, CDS, UTR are excluded).
    ///
    /// - Parameters:
    ///   - bundle: The reference bundle containing annotation tracks
    ///   - chromosomes: The chromosome list to scan
    public func buildIndex(bundle: ReferenceBundle, chromosomes: [ChromosomeInfo]) {
        // Check if any track has a SQLite database — use that instead
        for trackId in bundle.annotationTrackIds {
            if let trackInfo = bundle.annotationTrack(id: trackId),
               let dbPath = trackInfo.databasePath {
                if buildFromDatabase(bundle: bundle, trackId: trackId, databasePath: dbPath) {
                    return  // SQLite mode — skip BigBed scanning
                }
            }
        }

        // Fallback: scan BigBed files on background thread
        isBuilding = true
        searchLogger.info("AnnotationSearchIndex: Building index from BigBed for \(chromosomes.count) chromosomes, \(bundle.annotationTrackIds.count) tracks")

        let trackIds = bundle.annotationTrackIds

        // Use .utility QoS so this heavy I/O doesn't starve the viewer's
        // dedicated sequence and annotation fetch queues.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [SearchResult] = []
            var seenNames = Set<String>()

            for trackId in trackIds {
                for (chromIndex, chrom) in chromosomes.enumerated() {
                    searchLogger.info("AnnotationSearchIndex: Scanning \(chromIndex + 1)/\(chromosomes.count): \(chrom.name, privacy: .public)")
                    let region = GenomicRegion(
                        chromosome: chrom.name,
                        start: 0,
                        end: Int(chrom.length)
                    )
                    do {
                        let annotations = try bundle.getAnnotationsSync(trackId: trackId, region: region)
                        for ann in annotations {
                            // Filter to gene-level features only
                            let typeStr = ann.type.rawValue
                            guard indexableTypes.contains(typeStr) else { continue }

                            let name = ann.name
                            guard !name.isEmpty, name != "unknown" else { continue }

                            let interval = ann.intervals.first!
                            let lastInterval = ann.intervals.last!
                            let key = "\(name)|\(chrom.name)|\(interval.start)|\(lastInterval.end)"

                            if seenNames.insert(key).inserted {
                                let strandStr: String
                                switch ann.strand {
                                case .forward: strandStr = "+"
                                case .reverse: strandStr = "-"
                                case .unknown: strandStr = "."
                                }
                                results.append(SearchResult(
                                    name: name,
                                    chromosome: chrom.name,
                                    start: interval.start,
                                    end: lastInterval.end,
                                    trackId: trackId,
                                    type: typeStr,
                                    strand: strandStr
                                ))
                            }
                        }
                    } catch {
                        searchLogger.debug("AnnotationSearchIndex: Skipping \(trackId)/\(chrom.name, privacy: .public): \(error.localizedDescription)")
                    }
                }
            }

            // Sort results alphabetically
            results.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let count = results.count
            searchLogger.info("AnnotationSearchIndex: Built index with \(count) entries (background thread)")

            // Use Task { @MainActor in } instead of DispatchQueue.main.async.
            // In Swift 6.2, DispatchQueue.main.async closures dispatched from
            // non-MainActor contexts may never execute when accessing @MainActor state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entries = results
                self.isBuilding = false
                searchLogger.info("AnnotationSearchIndex: Index ready with \(count) entries")
                self.onBuildComplete?()
            }
        }
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

        if let db = database {
            let records = db.query(nameFilter: query, limit: limit)
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

        // Legacy in-memory search
        let lowered = query.lowercased()
        var results: [SearchResult] = []

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

        return results
    }

    /// Queries the index with both name and type filters.
    /// Only available in SQLite mode — returns nil for legacy mode.
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
        return db.queryCount(nameFilter: nameFilter, types: types)
    }

    /// Clears the index.
    public func clear() {
        entries = []
        database = nil
        isBuilding = false
    }
}
