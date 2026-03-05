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
        /// Structured INFO key-value pairs (nil for annotations or legacy databases).
        public let infoDict: [String: String]?
        /// Human-readable source name (e.g. VCF filename) for provenance display.
        public let sourceFile: String?

        /// Whether this result represents a variant (vs annotation).
        public var isVariant: Bool { ref != nil }

        public init(id: UUID = UUID(), name: String, chromosome: String, start: Int, end: Int,
                    trackId: String, type: String = "gene", strand: String = ".",
                    ref: String? = nil, alt: String? = nil, quality: Double? = nil,
                    filter: String? = nil, sampleCount: Int? = nil, variantRowId: Int64? = nil,
                    infoDict: [String: String]? = nil, sourceFile: String? = nil) {
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
            self.infoDict = infoDict
            self.sourceFile = sourceFile
        }
    }

    // MARK: - Properties

    /// In-memory entries used when SQLite mode is unavailable.
    private var entries: [SearchResult] = []

    /// SQLite annotation database handles (preferred mode).
    private var annotationDatabases: [(trackId: String, db: AnnotationDatabase)] = []

    /// Primary annotation database handle retained for backward compatibility.
    private var database: AnnotationDatabase?

    /// Variant SQLite database handle (for unified search).
    private(set) var variantDatabases: [(trackId: String, db: VariantDatabase)] = []

    /// Human-readable display name per variant track (from VariantTrackInfo.name).
    private var variantTrackNames: [String: String] = [:]

    /// Cached chromosome names per variant track for alias fallback matching.
    private var variantTrackChromosomes: [String: Set<String>] = [:]

    /// Bundle-provided chromosome alias groups keyed by exact lowercase token.
    private var bundleAliasGroupsByExact: [String: Set<String>] = [:]

    /// Bundle-provided chromosome alias groups keyed by canonical chromosome token.
    private var bundleAliasGroupsByCanonical: [String: Set<String>] = [:]

    /// Public accessor for variant database handles (for delete operations and background queries).
    public var variantDatabaseHandles: [(trackId: String, db: VariantDatabase)] { variantDatabases }

    /// Public accessor for annotation database handles (for background gene-region queries).
    public var annotationDatabaseHandles: [(trackId: String, db: AnnotationDatabase)] { annotationDatabases }

    /// Returns the human-readable display name for a variant track.
    public func variantTrackName(for trackId: String) -> String? { variantTrackNames[trackId] }

    /// Snapshot of per-track chromosome sets for background chromosome alias resolution.
    public var variantTrackChromosomeMap: [String: Set<String>] { variantTrackChromosomes }

    /// Track ID associated with the database (for SearchResult compatibility).
    private var databaseTrackId: String = ""

    /// Bundle identifier associated with this index for per-bundle persisted UI state.
    public private(set) var bundleIdentifier: String?

    /// Whether the index is currently being built.
    public private(set) var isBuilding: Bool = false

    /// Whether this index is backed by SQLite (vs in-memory).
    public var hasDatabaseBackend: Bool { !annotationDatabases.isEmpty || database != nil }

    /// Provides access to the underlying annotation database for enrichment lookups.
    public var annotationDatabase: AnnotationDatabase? { annotationDatabases.first?.db ?? database }

    /// Number of indexed entries.
    public var entryCount: Int {
        if !annotationDatabases.isEmpty {
            return annotationDatabases.reduce(0) { $0 + $1.db.totalCount() }
        }
        if let db = database {
            return db.totalCount()
        }
        return entries.count
    }

    /// All indexed entries (for populating the annotation table drawer).
    /// For SQLite mode, returns up to the display limit.
    public var allResults: [SearchResult] {
        if !annotationDatabases.isEmpty {
            var results: [SearchResult] = []
            for handle in annotationDatabases {
                let remaining = 5000 - results.count
                guard remaining > 0 else { break }
                let records = handle.db.query(limit: remaining)
                results.append(contentsOf: records.map { record in
                    SearchResult(
                        name: record.name,
                        chromosome: record.chromosome,
                        start: record.start,
                        end: record.end,
                        trackId: handle.trackId,
                        type: record.type,
                        strand: record.strand
                    )
                })
            }
            return results
        } else if let db = database {
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
        if !annotationDatabases.isEmpty {
            types = Set(annotationDatabases.flatMap { $0.db.allTypes() })
        } else if let db = database {
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

    /// Optional user override for haploid detection.
    /// `nil` means automatic detection from bundle metadata.
    private var haploidOverride: Bool?

    /// Reference genome total length from bundle metadata, when available.
    private var bundleGenomeTotalLength: Int64?

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
            let db = try AnnotationDatabase(url: dbURL)
            database = db
            databaseTrackId = trackId
            bundleIdentifier = bundle.manifest.identifier
            bundleGenomeTotalLength = bundle.manifest.genome?.totalLength ?? 0
            annotationDatabases = [(trackId: trackId, db: db)]
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
        variantTrackNames.removeAll()
        variantTrackChromosomes.removeAll()
        rebuildBundleAliasMaps(from: bundle)
        for vTrackId in bundle.variantTrackIds {
            guard let trackInfo = bundle.variantTrack(id: vTrackId),
                  let dbPath = trackInfo.databasePath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            do {
                let db = try VariantDatabase(url: dbURL, readWrite: true)
                variantDatabases.append((trackId: vTrackId, db: db))
                variantTrackNames[vTrackId] = trackInfo.name
                variantTrackChromosomes[vTrackId] = Set(db.allChromosomes())
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
        annotationDatabases.removeAll()
        database = nil
        databaseTrackId = ""
        bundleIdentifier = bundle.manifest.identifier
        bundleGenomeTotalLength = bundle.manifest.genome?.totalLength ?? 0
        rebuildBundleAliasMaps(from: bundle)

        for trackId in bundle.annotationTrackIds {
            if let trackInfo = bundle.annotationTrack(id: trackId),
               let dbPath = trackInfo.databasePath {
                let dbURL = bundle.url.appendingPathComponent(dbPath)
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
                do {
                    let db = try AnnotationDatabase(url: dbURL)
                    annotationDatabases.append((trackId: trackId, db: db))
                } catch {
                    searchLogger.warning("AnnotationSearchIndex: Failed to open annotation database '\(trackId, privacy: .public)': \(error.localizedDescription)")
                }
            }
        }

        if let first = annotationDatabases.first {
            database = first.db
            databaseTrackId = first.trackId
            let total = annotationDatabases.reduce(0) { $0 + $1.db.totalCount() }
            searchLogger.info("AnnotationSearchIndex: Opened \(self.annotationDatabases.count) annotation databases with \(total) annotations")
        }

        // Open variant databases even if there are no annotation databases.
        openVariantDatabases(bundle: bundle)
        entries = []
        isBuilding = false
        if annotationDatabases.isEmpty {
            searchLogger.warning("AnnotationSearchIndex: No annotation SQLite database found; annotation search will be empty")
        }
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

        if !annotationDatabases.isEmpty {
            for handle in annotationDatabases {
                let remaining = limit - results.count
                guard remaining > 0 else { break }
                let records = handle.db.query(nameFilter: query, limit: remaining)
                results.append(contentsOf: records.map { record in
                    SearchResult(
                        name: record.name,
                        chromosome: record.chromosome,
                        start: record.start,
                        end: record.end,
                        trackId: handle.trackId,
                        type: record.type,
                        strand: record.strand
                    )
                })
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
                results.append(contentsOf: variantRecordsToSearchResults(variantRecords, db: handle.db, trackId: handle.trackId))
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
        guard !annotationDatabases.isEmpty else { return nil }
        var results: [SearchResult] = []
        for handle in annotationDatabases {
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            let records = handle.db.query(nameFilter: nameFilter, types: types, limit: remaining)
            results.append(contentsOf: records.map { record in
                SearchResult(
                    name: record.name,
                    chromosome: record.chromosome,
                    start: record.start,
                    end: record.end,
                    trackId: handle.trackId,
                    type: record.type,
                    strand: record.strand
                )
            })
        }
        return results
    }

    /// Returns the count of annotations matching filters (SQLite mode only).
    public func queryCount(nameFilter: String = "", types: Set<String> = []) -> Int? {
        guard !annotationDatabases.isEmpty else { return nil }
        var count = annotationDatabases.reduce(0) { partial, handle in
            partial + handle.db.queryCount(nameFilter: nameFilter, types: types)
        }

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
                results.append(contentsOf: variantRecordsToSearchResults(variantRecords, db: handle.db, trackId: handle.trackId))
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
    public func queryVariantsOnly(nameFilter: String = "", types: Set<String> = [], infoFilters: [VariantDatabase.InfoFilter] = [], limit: Int = 5000) -> [SearchResult] {
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
                infoFilters: infoFilters,
                limit: remaining
            )
            results.append(contentsOf: variantRecordsToSearchResults(variantRecords, db: handle.db, trackId: handle.trackId))
        }
        return results
    }

    /// Returns count of variants only (no annotations).
    public func queryVariantCount(nameFilter: String = "", types: Set<String> = [], infoFilters: [VariantDatabase.InfoFilter] = []) -> Int {
        var count = 0
        for handle in variantDatabases {
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            if !requestedVariantTypes.isEmpty || types.isEmpty {
                count += handle.db.queryCountForTable(nameFilter: nameFilter, types: requestedVariantTypes, infoFilters: infoFilters)
            }
        }
        return count
    }

    /// Region-filtered variant query for viewport sync.
    public func queryVariantsInRegion(
        chromosome: String,
        start: Int,
        end: Int,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        limit: Int = 5000
    ) -> [SearchResult] {
        var results: [SearchResult] = []
        for handle in variantDatabases {
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                let chunkLimit = limit - results.count
                guard chunkLimit > 0 else { break }
                let variantRecords = handle.db.queryForTableInRegion(
                    chromosome: queryChrom,
                    start: start,
                    end: end,
                    nameFilter: nameFilter,
                    types: types,
                    infoFilters: infoFilters,
                    limit: chunkLimit
                )
                if !variantRecords.isEmpty {
                    results.append(contentsOf: variantRecordsToSearchResults(variantRecords, db: handle.db, trackId: handle.trackId))
                }
            }
        }
        return results
    }

    /// Region-filtered variant count for viewport sync.
    public func queryVariantCountInRegion(
        chromosome: String,
        start: Int,
        end: Int,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = []
    ) -> Int {
        var count = 0
        for handle in variantDatabases {
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                count += handle.db.queryCountInRegion(
                    chromosome: queryChrom,
                    start: start,
                    end: end,
                    nameFilter: nameFilter,
                    types: types,
                    infoFilters: infoFilters
                )
            }
        }
        return count
    }

    /// Queries variants overlapping genes specified by name.
    ///
    /// For each gene name:
    /// 1. Finds annotation regions via `queryAnnotationsOnly`
    /// 2. Queries variants in those regions
    /// 3. Also matches variants with INFO GENE/SYMBOL keys via LIKE filter
    ///
    /// Returns de-duplicated results up to `limit`.
    public func queryVariantsForGenes(
        _ geneNames: [String],
        types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        limit: Int = 5000
    ) -> [SearchResult] {
        guard !geneNames.isEmpty else { return [] }

        var seenRowIds = Set<Int64>()
        var results: [SearchResult] = []

        for gene in geneNames {
            let trimmed = gene.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 1. Find annotation regions for this gene
            let annotations = queryAnnotationsOnly(nameFilter: trimmed, limit: 20)
            for ann in annotations {
                guard results.count < limit else { break }
                let regionVariants = queryVariantsInRegion(
                    chromosome: ann.chromosome,
                    start: ann.start,
                    end: ann.end,
                    types: types,
                    infoFilters: infoFilters,
                    limit: limit - results.count
                )
                for v in regionVariants {
                    if seenRowIds.insert(v.variantRowId ?? -1).inserted || v.variantRowId == nil {
                        results.append(v)
                    }
                }
            }

            // 2. Also search by INFO GENE/SYMBOL fields
            guard results.count < limit else { break }
            let geneInfoKeys = ["GENE", "Gene", "gene", "GENEINFO", "SYMBOL", "ANN_Gene", "CSQ_SYMBOL"]
            let availableKeys = Set(variantInfoKeys.map(\.key))
            for geneKey in geneInfoKeys {
                guard availableKeys.contains(geneKey), results.count < limit else { continue }
                var mergedFilters = infoFilters
                mergedFilters.append(VariantDatabase.InfoFilter(key: geneKey, op: .like, value: trimmed))
                let infoResults = queryVariantsOnly(
                    types: types,
                    infoFilters: mergedFilters,
                    limit: limit - results.count
                )
                for v in infoResults {
                    if seenRowIds.insert(v.variantRowId ?? -1).inserted || v.variantRowId == nil {
                        results.append(v)
                    }
                }
            }
        }

        return Array(results.prefix(limit))
    }

    /// All distinct annotation types only (no variant types).
    public var annotationTypes: [String] {
        if !annotationDatabases.isEmpty {
            return Set(annotationDatabases.flatMap { $0.db.allTypes() }).sorted()
        }
        if let db = database {
            return db.allTypes().sorted()
        }
        return Set(entries.map { $0.type }).sorted()
    }

    /// Track-aware annotation lookup for drawer/inspector enrichment.
    public func lookupAnnotation(for result: SearchResult) -> AnnotationDatabaseRecord? {
        let candidates = annotationChromosomeCandidates(for: result.chromosome)
        if let matched = annotationDatabases.first(where: { $0.trackId == result.trackId }) {
            for chromosome in candidates {
                if let record = matched.db.lookupAnnotation(
                    name: result.name,
                    chromosome: chromosome,
                    start: result.start,
                    end: result.end
                ) {
                    return record
                }
            }
        }
        for handle in annotationDatabases {
            for chromosome in candidates {
                if let record = handle.db.lookupAnnotation(
                    name: result.name,
                    chromosome: chromosome,
                    start: result.start,
                    end: result.end
                ) {
                    return record
                }
            }
        }
        return nil
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

    /// INFO field definitions from all variant databases.
    ///
    /// Returns the union of INFO keys across all loaded variant databases,
    /// used by the drawer to create dynamic columns.
    public var variantInfoKeys: [(key: String, type: String, number: String, description: String)] {
        typealias InfoAccumulator = (types: Set<String>, number: String, description: String)
        var merged: [String: InfoAccumulator] = [:]
        for handle in variantDatabases {
            for def in handle.db.infoKeys() {
                guard handle.db.hasNonEmptyInfoValue(forKey: def.key) else { continue }
                if var existing = merged[def.key] {
                    existing.types.insert(def.type)
                    merged[def.key] = existing
                } else {
                    merged[def.key] = (types: [def.type], number: def.number, description: def.description)
                }
            }
        }
        return merged.keys.sorted().map { key in
            let entry = merged[key]!
            let resolvedType = entry.types.count > 1 ? "String" : (entry.types.first ?? "String")
            return (key: key, type: resolvedType, number: entry.number, description: entry.description)
        }
    }

    /// Returns INFO presets suitable for filter chips.
    /// Includes keys whose distinct value count is <= `maxDistinctValues`.
    public func variantInfoPresetValues(
        maxDistinctValues: Int = 20,
        maxKeys: Int = 8
    ) -> [(key: String, values: [String])] {
        guard maxDistinctValues > 0, maxKeys > 0 else { return [] }
        var presets: [(key: String, values: [String])] = []
        for def in variantInfoKeys {
            var valueSet = Set<String>()
            var exceeded = false
            for handle in variantDatabases {
                let values = handle.db.distinctInfoValues(forKey: def.key, limit: maxDistinctValues + 1)
                for value in values {
                    valueSet.insert(value)
                    if valueSet.count > maxDistinctValues {
                        exceeded = true
                        break
                    }
                }
                if exceeded { break }
            }
            if exceeded { continue }
            let sortedValues = valueSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if sortedValues.isEmpty { continue }
            presets.append((key: def.key, values: sortedValues))
            if presets.count >= maxKeys { break }
        }
        return presets
    }

    /// Returns true if the variant data likely comes from a haploid organism (virus/bacteria).
    ///
    /// Heuristic: total genome span (sum of max variant positions per chromosome) < 10 Mb.
    /// This reliably separates viral (~10-30 kb) and most bacterial (~1-10 Mb) genomes from
    /// eukaryotic genomes (>50 Mb). When true, within-sample allele frequency filters
    /// become available since each position may have a continuous AF rather than discrete
    /// diploid genotypes.
    public var isLikelyHaploidOrganism: Bool {
        if let override = haploidOverride {
            return override
        }
        if let genomeLength = bundleGenomeTotalLength, genomeLength > 0 {
            // Viral genomes are typically <100 kb and most bacterial genomes are <10 Mb.
            // Larger eukaryotic genomes are typically orders of magnitude larger.
            return genomeLength < 10_000_000
        }
        var totalSpan: Int64 = 0
        for handle in variantDatabases {
            let maxPositions = handle.db.chromosomeMaxPositions()
            for (_, maxPos) in maxPositions {
                totalSpan += Int64(maxPos)
            }
        }
        // Threshold: 10 Mb. Viral genomes are <100 kb, bacteria are <10 Mb.
        // Eukaryotic genomes are >50 Mb (even C. elegans is 100 Mb).
        return totalSpan > 0 && totalSpan < 10_000_000
    }

    /// Sets an explicit haploid-mode override.
    /// - Parameter value: `true` for forced haploid, `false` for forced diploid, `nil` for auto-detect.
    public func setHaploidOverride(_ value: Bool?) {
        haploidOverride = value
    }

    /// Returns the current haploid-mode override.
    public var haploidOverrideValue: Bool? { haploidOverride }

    /// Clears the index.
    public func clear() {
        entries = []
        database = nil
        annotationDatabases = []
        variantDatabases = []
        variantTrackNames = [:]
        variantTrackChromosomes = [:]
        bundleAliasGroupsByExact = [:]
        bundleAliasGroupsByCanonical = [:]
        bundleIdentifier = nil
        bundleGenomeTotalLength = nil
        haploidOverride = nil
        isBuilding = false
    }

    /// Clears only variant databases, leaving annotation data intact.
    public func clearVariantDatabases() {
        variantDatabases.removeAll()
        variantTrackNames.removeAll()
        variantTrackChromosomes.removeAll()
    }

    // MARK: - Private Helpers

    /// Converts variant records to SearchResults, batch-fetching INFO dictionaries.
    private func variantRecordsToSearchResults(
        _ records: [VariantDatabaseRecord],
        db: VariantDatabase,
        trackId: String
    ) -> [SearchResult] {
        guard !records.isEmpty else { return [] }
        let variantIds = records.compactMap(\.id)
        let infoDicts = db.batchInfoValues(variantIds: variantIds)
        let sourceName = variantTrackNames[trackId]
        return records.map { record in
            let infoDict = record.id.flatMap { infoDicts[$0] }
            return record.toSearchResult(trackId: trackId, infoDict: infoDict, sourceFile: sourceName)
        }
    }

    /// Returns chromosome names to try for variant queries in this track.
    /// Includes direct match plus normalized/alias fallbacks.
    private func resolvedChromosomeCandidates(for chromosome: String, trackId: String) -> [String] {
        let available = variantTrackChromosomes[trackId] ?? []
        if available.isEmpty || available.contains(chromosome) { return [chromosome] }

        var ordered: [String] = [chromosome]

        // 1) Bundle-defined alias groups (bi-directional), if available.
        let lower = chromosome.lowercased()
        if let group = bundleAliasGroupsByExact[lower]
            ?? bundleAliasGroupsByCanonical[canonicalChromosomeName(chromosome)] {
            for alias in group where available.contains(alias) {
                ordered.append(alias)
            }
        }

        // 2) Fallback to canonical matching against VCF chromosome names.
        let canonical = canonicalChromosomeName(chromosome)
        for candidate in available {
            if canonicalChromosomeName(candidate) == canonical {
                ordered.append(candidate)
            }
        }
        if ordered.count > 1 {
            return Array(NSOrderedSet(array: ordered)) as? [String] ?? ordered
        }
        return [chromosome]
    }

    /// Returns candidate chromosome names for annotation lookups.
    private func annotationChromosomeCandidates(for chromosome: String) -> [String] {
        var candidates: [String] = [chromosome]
        let trimmed = chromosome.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let group = bundleAliasGroupsByExact[lower]
            ?? bundleAliasGroupsByCanonical[canonicalChromosomeName(trimmed)] {
            candidates.append(contentsOf: group)
        }

        if lower.hasPrefix("chr") {
            candidates.append(String(trimmed.dropFirst(3)))
        } else {
            candidates.append("chr\(trimmed)")
        }

        if let dot = trimmed.firstIndex(of: ".") {
            let withoutVersion = String(trimmed[..<dot])
            candidates.append(withoutVersion)
            if withoutVersion.lowercased().hasPrefix("chr") {
                candidates.append(String(withoutVersion.dropFirst(3)))
            } else {
                candidates.append("chr\(withoutVersion)")
            }
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    /// Canonical chromosome key used for alias fallback matching.
    private func canonicalChromosomeName(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("chr") {
            value = String(value.dropFirst(3))
        }
        if let dot = value.firstIndex(of: ".") {
            value = String(value[..<dot])
        }
        return value
    }

    /// Builds alias lookup maps from bundle chromosome names + aliases.
    ///
    /// This enables bi-directional lookup between annotation contig names and VCF contig names
    /// (e.g. `NC_041760.1` <-> `7`) when the bundle includes these alias mappings.
    private func rebuildBundleAliasMaps(from bundle: ReferenceBundle) {
        bundleAliasGroupsByExact = [:]
        bundleAliasGroupsByCanonical = [:]

        for chromosome in bundle.manifest.genome?.chromosomes ?? [] {
            var group = Set<String>()
            group.insert(chromosome.name)
            group.formUnion(chromosome.aliases)

            // Expand common representation variants for each alias token.
            let expanded = group.flatMap { aliasExpansions(for: $0) }
            group.formUnion(expanded)

            for token in group {
                let lower = token.lowercased()
                bundleAliasGroupsByExact[lower, default: []].formUnion(group)
                let canonical = canonicalChromosomeName(token)
                bundleAliasGroupsByCanonical[canonical, default: []].formUnion(group)
            }
        }
    }

    /// Generates simple equivalent alias forms:
    /// - with/without `chr` prefix
    /// - with/without dotted version suffix
    private func aliasExpansions(for token: String) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results = Set<String>()
        results.insert(trimmed)

        let lower = trimmed.lowercased()
        if lower.hasPrefix("chr") {
            results.insert(String(trimmed.dropFirst(3)))
        } else {
            results.insert("chr\(trimmed)")
        }

        if let dot = trimmed.firstIndex(of: ".") {
            let withoutVersion = String(trimmed[..<dot])
            results.insert(withoutVersion)
            if withoutVersion.lowercased().hasPrefix("chr") {
                results.insert(String(withoutVersion.dropFirst(3)))
            } else {
                results.insert("chr\(withoutVersion)")
            }
        }

        return Array(results)
    }
}

// MARK: - VariantDatabaseRecord → SearchResult Conversion

extension VariantDatabaseRecord {
    /// Converts this variant record to an `AnnotationSearchIndex.SearchResult`
    /// for unified display in the annotation table drawer.
    public func toSearchResult(
        trackId: String = "variants",
        infoDict: [String: String]? = nil,
        sourceFile: String? = nil
    ) -> AnnotationSearchIndex.SearchResult {
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
            variantRowId: id,
            infoDict: infoDict,
            sourceFile: sourceFile
        )
    }
}
