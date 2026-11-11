// AnnotationTableDrawerView+VariantQueryContext.swift - AnnotationVariantQueryContext and the off-main query helpers of the annotation drawer
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

/// Snapshot of variant database state needed for background queries.
/// All fields are `Sendable` (VariantDatabase/AnnotationDatabase are @unchecked Sendable).
struct AnnotationVariantQueryContext: @unchecked Sendable {
    let databases: [(trackId: String, db: VariantDatabase)]
    let trackNames: [String: String]
    let trackChromosomes: [String: Set<String>]
    let annotationDatabases: [(trackId: String, db: AnnotationDatabase)]
    let infoKeys: Set<String>
    /// Maps reference chromosome names → VCF chromosome names (from contig length matching).
    let variantAliasMap: [String: String]
    let formatOverlay: VariantFormatOverlaySnapshot

    init(
        databases: [(trackId: String, db: VariantDatabase)],
        trackNames: [String: String],
        trackChromosomes: [String: Set<String>],
        annotationDatabases: [(trackId: String, db: AnnotationDatabase)],
        infoKeys: Set<String>,
        variantAliasMap: [String: String],
        formatOverlay: VariantFormatOverlaySnapshot = VariantFormatOverlaySnapshot()
    ) {
        self.databases = databases
        self.trackNames = trackNames
        self.trackChromosomes = trackChromosomes
        self.annotationDatabases = annotationDatabases
        self.infoKeys = infoKeys
        self.variantAliasMap = variantAliasMap
        self.formatOverlay = formatOverlay
    }

    func resolvedChromosomeCandidates(for chromosome: String, trackId: String) -> [String] {
        let available = trackChromosomes[trackId] ?? []
        return resolveVariantChromosomeCandidates(
            requestedChromosome: chromosome,
            availableChromosomes: available,
            aliasMap: variantAliasMap
        )
    }

    func variantRecordsToSearchResults(
        _ records: [VariantDatabaseRecord],
        db: VariantDatabase,
        trackId: String
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard !records.isEmpty else { return [] }
        let variantIds = records.compactMap(\.id)
        let infoDicts = db.batchInfoValues(variantIds: variantIds)
        let sourceName = trackNames[trackId]
        return records.map { record in
            let storedInfo = record.id.flatMap { infoDicts[$0] } ?? [:]
            let infoDict = formatOverlay.projectedInfo(trackID: trackId, record: record, existing: storedInfo)
            return record.toSearchResult(trackId: trackId, infoDict: infoDict, sourceFile: sourceName)
        }
    }

    private func projectedFilters(
        for trackID: String,
        from filters: [VariantDatabase.InfoFilter]
    ) -> [VariantDatabase.InfoFilter] {
        let projected = formatOverlay.projectedKeysByTrack[trackID] ?? []
        let anyProjected = formatOverlay.allProjectedKeys
        return filters.filter {
            projected.contains($0.key) || ($0.value.isEmpty && anyProjected.contains($0.key))
        }
    }

    private func smartFilterUsesProjectedAF(_ smartFilter: VariantSmartFilter?, trackID: String) -> Bool {
        guard formatOverlay.projectedKeysByTrack[trackID]?.contains("AF") == true,
              let smartFilter else { return false }
        return smartFilter.predicates.contains { predicate in
            switch predicate {
            case .sample(let value): return value.field == .alleleFrequency
            case .count(let value): return value.predicate.field == .alleleFrequency
            case .sampleFieldComparison(let value): return value.lhs.field == .alleleFrequency
            }
        }
    }

    private func finalizeProjectionQuery(
        _ rows: [AnnotationSearchIndex.SearchResult],
        limit: Int,
        shouldCancel: (() -> Bool)?
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard shouldCancel?() != true else { return [] }
        guard limit < rows.count else { return rows }
        return Array(rows.prefix(max(0, limit)))
    }

    func queryVariantsInRegion(
        chromosome: String, start: Int, end: Int,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        smartFilter: VariantSmartFilter? = nil,
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            let deferredFilters = projectedFilters(for: handle.trackId, from: infoFilters)
            let deferredSmartFilter = smartFilterUsesProjectedAF(smartFilter, trackID: handle.trackId)
            let requiresComplete = !deferredFilters.isEmpty || deferredSmartFilter
            let sqlFilters = requiresComplete
                ? infoFilters.filter { filter in !deferredFilters.contains { $0.key == filter.key } }
                : infoFilters
            let remaining = requiresComplete ? handle.db.totalCount() : limit - results.count
            guard remaining > 0 else { continue }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                if shouldCancel?() == true { break }
                let chunkLimit = requiresComplete ? handle.db.totalCount() : limit - results.count
                guard chunkLimit > 0 else { break }
                let records = handle.db.queryForTableInRegion(
                    chromosome: queryChrom, start: start, end: end,
                    nameFilter: nameFilter, types: types,
                    infoFilters: sqlFilters, sampleNames: sampleNames,
                    smartFilter: deferredSmartFilter ? nil : smartFilter,
                    activeTokens: requiresComplete ? [] : activeTokens, limit: chunkLimit
                )
                if !records.isEmpty {
                    let converted = variantRecordsToSearchResults(records, db: handle.db, trackId: handle.trackId)
                    for (index, row) in converted.enumerated() {
                        if index.isMultiple(of: 256), shouldCancel?() == true { return [] }
                        if deferredFilters.allSatisfy({ VariantFormatOverlaySnapshot.matches(row.infoDict ?? [:], filter: $0) })
                            && (!deferredSmartFilter || smartFilter.map {
                                formatOverlay.matches($0, trackID: handle.trackId, row: row)
                            } == true) {
                            results.append(row)
                        }
                    }
                }
            }
        }
        return finalizeProjectionQuery(results, limit: limit, shouldCancel: shouldCancel)
    }

    func queryVariantCountInRegion(
        chromosome: String, start: Int, end: Int,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        smartFilter: VariantSmartFilter? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) -> Int {
        let hasProjectedFilter = databases.contains { handle in
            !projectedFilters(for: handle.trackId, from: infoFilters).isEmpty
                || smartFilterUsesProjectedAF(smartFilter, trackID: handle.trackId)
        }
        if hasProjectedFilter {
            let completeLimit = databases.reduce(0) { $0 + max(0, $1.db.totalCount()) }
            return queryVariantsInRegion(
                chromosome: chromosome, start: start, end: end,
                nameFilter: nameFilter, types: types, infoFilters: infoFilters,
                sampleNames: sampleNames, smartFilter: smartFilter,
                limit: completeLimit, shouldCancel: shouldCancel
            ).count
        }
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                if shouldCancel?() == true { break }
                count += handle.db.queryCountInRegion(
                    chromosome: queryChrom, start: start, end: end,
                    nameFilter: nameFilter, types: types,
                    infoFilters: infoFilters, sampleNames: sampleNames,
                    smartFilter: smartFilter
                )
            }
        }
        return count
    }

    func queryVariantsOnly(
        chromosome: String? = nil,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        smartFilter: VariantSmartFilter? = nil,
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            let deferredFilters = projectedFilters(for: handle.trackId, from: infoFilters)
            let deferredSmartFilter = smartFilterUsesProjectedAF(smartFilter, trackID: handle.trackId)
            let requiresComplete = !deferredFilters.isEmpty || deferredSmartFilter
            let sqlFilters = requiresComplete
                ? infoFilters.filter { filter in !deferredFilters.contains { $0.key == filter.key } }
                : infoFilters
            let remaining = requiresComplete ? handle.db.totalCount() : limit - results.count
            guard remaining > 0 else { continue }
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            guard !requestedVariantTypes.isEmpty || types.isEmpty else { continue }
            // Resolve the chromosome name for this track's database
            let dbChromosome: String? = chromosome.flatMap { chrom in
                let candidates = resolvedChromosomeCandidates(for: chrom, trackId: handle.trackId)
                return candidates.first
            }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            let records = handle.db.queryForTable(
                chromosome: dbChromosome,
                nameFilter: nameFilter,
                types: types.isEmpty ? [] : requestedVariantTypes,
                infoFilters: sqlFilters, sampleNames: sampleNames,
                smartFilter: deferredSmartFilter ? nil : smartFilter,
                activeTokens: requiresComplete ? [] : activeTokens, limit: remaining
            )
            let converted = variantRecordsToSearchResults(records, db: handle.db, trackId: handle.trackId)
            for (index, row) in converted.enumerated() {
                if index.isMultiple(of: 256), shouldCancel?() == true { return [] }
                if deferredFilters.allSatisfy({ VariantFormatOverlaySnapshot.matches(row.infoDict ?? [:], filter: $0) })
                    && (!deferredSmartFilter || smartFilter.map {
                        formatOverlay.matches($0, trackID: handle.trackId, row: row)
                    } == true) {
                    results.append(row)
                }
            }
        }
        return finalizeProjectionQuery(results, limit: limit, shouldCancel: shouldCancel)
    }

    func queryVariantCount(
        chromosome: String? = nil,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        smartFilter: VariantSmartFilter? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) -> Int {
        let hasProjectedFilter = databases.contains { handle in
            !projectedFilters(for: handle.trackId, from: infoFilters).isEmpty
                || smartFilterUsesProjectedAF(smartFilter, trackID: handle.trackId)
        }
        if hasProjectedFilter {
            let completeLimit = databases.reduce(0) { $0 + max(0, $1.db.totalCount()) }
            return queryVariantsOnly(
                chromosome: chromosome, nameFilter: nameFilter, types: types,
                infoFilters: infoFilters, sampleNames: sampleNames, smartFilter: smartFilter,
                limit: completeLimit, shouldCancel: shouldCancel
            ).count
        }
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            if !requestedVariantTypes.isEmpty || types.isEmpty {
                let dbChromosome: String? = chromosome.flatMap { chrom in
                    let candidates = resolvedChromosomeCandidates(for: chrom, trackId: handle.trackId)
                    return candidates.first
                }
                handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
                defer { handle.db.removeQueryTimeout() }
                count += handle.db.queryCountForTable(
                    chromosome: dbChromosome,
                    nameFilter: nameFilter,
                    types: requestedVariantTypes,
                    infoFilters: infoFilters,
                    sampleNames: sampleNames,
                    smartFilter: smartFilter
                )
            }
        }
        return count
    }

    func queryVariantsForGenes(
        _ geneNames: [String],
        types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        smartFilter: VariantSmartFilter? = nil,
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> (results: [AnnotationSearchIndex.SearchResult], resolvedRegions: [GeneRegion]) {
        guard !geneNames.isEmpty else { return ([], []) }
        var seenRows = Set<AnnotationSearchIndex.SearchResult.VariantIdentity>()
        var results: [AnnotationSearchIndex.SearchResult] = []
        let resolvedRegions = resolveGeneRegions(geneNames)
        let annotationRegions = resolvedRegions.map { (chromosome: $0.chromosome, start: $0.start, end: $0.end, gene: $0.name) }

        // Query variants overlapping pre-resolved annotation regions.
        for region in annotationRegions {
            if shouldCancel?() == true { break }
            guard results.count < limit else { break }
            let regionVariants = queryVariantsInRegion(
                chromosome: region.chromosome, start: region.start, end: region.end,
                types: types,
                infoFilters: infoFilters,
                sampleNames: sampleNames,
                smartFilter: smartFilter,
                activeTokens: activeTokens,
                limit: limit - results.count,
                shouldCancel: shouldCancel
            )
            for v in regionVariants {
                if v.variantIdentity.map({ seenRows.insert($0).inserted }) ?? true {
                    results.append(v)
                }
            }
        }

        // Also search by INFO GENE/SYMBOL fields.
        let geneInfoKeyNames = ["GENE", "Gene", "gene", "GENEINFO", "SYMBOL", "ANN_Gene", "CSQ_SYMBOL"]
        for gene in geneNames {
            if shouldCancel?() == true { break }
            let trimmed = gene.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, results.count < limit else { continue }
            for geneKey in geneInfoKeyNames {
                if shouldCancel?() == true { break }
                guard infoKeys.contains(geneKey), results.count < limit else { continue }
                var mergedFilters = infoFilters
                mergedFilters.append(VariantDatabase.InfoFilter(key: geneKey, op: .like, value: trimmed))
                let infoResults = queryVariantsOnly(
                    types: types,
                    infoFilters: mergedFilters,
                    sampleNames: sampleNames,
                    smartFilter: smartFilter,
                    activeTokens: activeTokens,
                    limit: limit - results.count,
                    shouldCancel: shouldCancel
                )
                for v in infoResults {
                    if v.variantIdentity.map({ seenRows.insert($0).inserted }) ?? true {
                        results.append(v)
                    }
                }
            }
        }

        return (Array(results.prefix(limit)), resolvedRegions)
    }

    func resolveGeneRegions(_ geneNames: [String]) -> [GeneRegion] {
        let preferredTypes = ["gene", "mrna", "transcript", "cds", "exon"]
        var resolved: [GeneRegion] = []
        var seen = Set<String>()

        for rawName in geneNames {
            let queryName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !queryName.isEmpty else { continue }
            let normalized = queryName.lowercased()
            guard seen.insert(normalized).inserted else { continue }

            var candidates: [AnnotationDatabaseRecord] = []
            for handle in annotationDatabases {
                let rows = handle.db.query(nameFilter: queryName, limit: 64)
                if !rows.isEmpty { candidates.append(contentsOf: rows) }
            }
            guard !candidates.isEmpty else { continue }

            func score(_ row: AnnotationDatabaseRecord) -> (Int, Int, Int, String, Int) {
                let nameLower = row.name.lowercased()
                let nameScore: Int
                if nameLower == normalized {
                    nameScore = 0
                } else if nameLower.hasPrefix(normalized) {
                    nameScore = 1
                } else if nameLower.contains(normalized) {
                    nameScore = 2
                } else {
                    nameScore = 3
                }
                let typeScore = preferredTypes.firstIndex(of: row.type.lowercased()) ?? (preferredTypes.count + 1)
                let span = max(0, row.end - row.start)
                return (nameScore, typeScore, span, row.chromosome, row.start)
            }

            guard let best = candidates.min(by: { score($0) < score($1) }) else { continue }
            resolved.append(GeneRegion(name: queryName, chromosome: best.chromosome, start: best.start, end: best.end))
        }

        return resolved
    }
}

/// Adaptive post-filtering loop (free function, safe to call from any thread).
func fetchVariantsAdaptive(
    maxDisplayCount: Int,
    initialFetchLimit: Int,
    totalSQLMatchCount: Int?,
    applyPostFiltering: Bool,
    fetch: (Int) -> [AnnotationSearchIndex.SearchResult],
    postFilter: ([AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult],
    shouldCancel: (() -> Bool)? = nil
) -> [AnnotationSearchIndex.SearchResult] {
    let minimumLimit = max(maxDisplayCount, initialFetchLimit)
    if !applyPostFiltering {
        if shouldCancel?() == true { return [] }
        return Array(fetch(minimumLimit).prefix(maxDisplayCount))
    }

    var fetchLimit = minimumLimit
    var previousRawCount = -1
    var filtered: [AnnotationSearchIndex.SearchResult] = []

    while true {
        if shouldCancel?() == true { break }
        let raw = fetch(fetchLimit)
        if shouldCancel?() == true { break }
        filtered = postFilter(raw)
        if filtered.count >= maxDisplayCount { break }
        if raw.count < fetchLimit { break }
        if let totalSQLMatchCount, fetchLimit >= totalSQLMatchCount { break }
        if raw.count == previousRawCount { break }
        previousRawCount = raw.count

        let nextCandidate = max(fetchLimit * 2, fetchLimit + maxDisplayCount * 2)
        if let totalSQLMatchCount {
            let next = min(totalSQLMatchCount, nextCandidate)
            if next <= fetchLimit { break }
            fetchLimit = next
        } else {
            let next = min(maxDisplayCount * 40, nextCandidate)
            if next <= fetchLimit { break }
            fetchLimit = next
        }
    }

    return Array(filtered.prefix(maxDisplayCount))
}

/// Annotation-table fetch loop for background database queries.
func fetchAnnotationRowsForDisplayOffMain(
    context: AnnotationQueryContext,
    nameFilter: String,
    typeFilter: Set<String>,
    query annotationQuery: AnnotationTableDrawerView.AnnotationFilterQuery,
    databaseColumnFilters: [AnnotationDatabase.ColumnFilterClause],
    allColumnFilters: [AnnotationTableDrawerView.ColumnFilterClause],
    requiresPostOnlyColumnFiltering: Bool,
    maxDisplayCount: Int,
    shouldCancel: (() -> Bool)? = nil
) -> [AnnotationSearchIndex.SearchResult] {
    let targetCount = maxDisplayCount + 1
    var fetchLimit = targetCount

    while true {
        if shouldCancel?() == true { return [] }
        let results = context.queryAnnotationsOnly(
            nameFilter: nameFilter,
            types: typeFilter,
            chromosome: annotationQuery.chromosome,
            regionStart: annotationQuery.start,
            regionEnd: annotationQuery.end,
            strand: annotationQuery.strand,
            columnFilters: databaseColumnFilters,
            limit: fetchLimit,
            shouldCancel: shouldCancel
        )
        if shouldCancel?() == true { return [] }
        let filtered = applyAnnotationColumnFiltersOffMain(
            to: applyAnnotationAdvancedFiltersOffMain(results, query: annotationQuery),
            clauses: allColumnFilters
        )
        if shouldCancel?() == true { return [] }

        if !requiresPostOnlyColumnFiltering
            || filtered.count >= targetCount
            || results.count < fetchLimit {
            return Array(filtered.prefix(targetCount))
        }

        fetchLimit = max(fetchLimit * 2, fetchLimit + targetCount)
    }
}

func applyAnnotationAdvancedFiltersOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    query: AnnotationTableDrawerView.AnnotationFilterQuery
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { row in
        if let chr = query.chromosome, row.chromosome.caseInsensitiveCompare(chr) != .orderedSame { return false }
        if let strand = query.strand, row.strand.caseInsensitiveCompare(strand) != .orderedSame { return false }
        if let start = query.start, row.end <= start { return false }
        if let end = query.end, row.start >= end { return false }
        return true
    }
}

func applyAnnotationColumnFiltersOffMain(
    to rows: [AnnotationSearchIndex.SearchResult],
    clauses: [AnnotationTableDrawerView.ColumnFilterClause]
) -> [AnnotationSearchIndex.SearchResult] {
    guard !clauses.isEmpty else { return rows }
    return rows.filter { row in
        clauses.allSatisfy { clause in
            let actual = annotationColumnValueOffMain(row, key: clause.key)
            return annotationColumnMatchesOffMain(
                actual: actual,
                op: clause.op,
                expected: clause.value,
                key: clause.key
            )
        }
    }
}

func annotationColumnValueOffMain(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
    switch key {
    case "name":
        return row.name
    case "track_id":
        return row.trackId
    case "track_name":
        return row.trackName ?? row.trackId
    case "type":
        return row.type
    case "chromosome":
        return row.chromosome
    case "start":
        // Must match annotationColumnValue: filters see the displayed 1-based start.
        return String(GenomicCoordinateDisplay.displayStart(row.start))
    case "end":
        return String(GenomicCoordinateDisplay.displayEnd(row.end))
    case "size":
        return String(row.end - row.start)
    case "strand":
        return row.strand
    default:
        if key.hasPrefix("attr_") {
            let attributeKey = String(key.dropFirst(5))
            return row.attributes?[attributeKey] ?? ""
        }
        return ""
    }
}

func annotationColumnMatchesOffMain(actual: String, op: String, expected: String, key: String) -> Bool {
    let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
    if isAnnotationFilterNumericKeyOffMain(key),
       let lhs = Double(normalizedActual),
       let rhs = Double(normalizedExpected) {
        switch op {
        case ">": return lhs > rhs
        case ">=": return lhs >= rhs
        case "<": return lhs < rhs
        case "<=": return lhs <= rhs
        case "=": return lhs == rhs
        case "!=": return lhs != rhs
        default: break
        }
    }
    return textColumnMatchesOffMain(actual: normalizedActual, op: op, expected: normalizedExpected)
}

func isAnnotationFilterNumericKeyOffMain(_ key: String) -> Bool {
    switch key {
    case "start", "end", "size":
        return true
    default:
        if key.hasPrefix("attr_") {
            let attributeKey = String(key.dropFirst(5))
            return isNumericAnnotationAttributeKeyOffMain(attributeKey)
        }
        return false
    }
}

func isNumericAnnotationAttributeKeyOffMain(_ key: String) -> Bool {
    switch key {
    case "flag", "mapq", "pos_1_based", "alignment_start", "alignment_end",
         "reference_length", "query_length", "mate_position_1_based", "template_length",
         "tag_NM", "tag_AS":
        return true
    default:
        return false
    }
}

func textColumnMatchesOffMain(actual: String, op: String, expected: String) -> Bool {
    switch op {
    case "=":
        if expected.isEmpty { return actual.isEmpty }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    case "!=":
        if expected.isEmpty { return !actual.isEmpty }
        return actual.caseInsensitiveCompare(expected) != .orderedSame
    case "~", ":":
        if expected.isEmpty { return true }
        return actual.localizedCaseInsensitiveContains(expected)
    case "!~":
        if expected.isEmpty { return true }
        return !actual.localizedCaseInsensitiveContains(expected)
    case "^=":
        if expected.isEmpty { return true }
        return actual.lowercased().hasPrefix(expected.lowercased())
    case "$=":
        if expected.isEmpty { return true }
        return actual.lowercased().hasSuffix(expected.lowercased())
    default:
        if expected.isEmpty { return true }
        return actual.localizedCaseInsensitiveContains(expected)
    }
}

/// Pure variant advanced filters (free function, safe to call from any thread).
func applyVariantAdvancedFiltersOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    query: AnnotationTableDrawerView.VariantFilterQuery  // fileprivate access
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { row in
        if let explicitTypeFilter = query.explicitTypeFilter, !explicitTypeFilter.isEmpty {
            let matchesType = explicitTypeFilter.contains { candidate in
                row.type.caseInsensitiveCompare(candidate) == .orderedSame
            }
            if !matchesType { return false }
        }
        if let filterVal = query.filterValue {
            let rowFilter = row.filter ?? "."
            if rowFilter.caseInsensitiveCompare(filterVal) != .orderedSame { return false }
        }
        if let minQ = query.minQuality {
            let q = row.quality ?? -Double.greatestFiniteMagnitude
            if query.minQualityInclusive ? q < minQ : q <= minQ { return false }
        }
        if let maxQ = query.maxQuality {
            let q = row.quality ?? Double.greatestFiniteMagnitude
            if query.maxQualityInclusive ? q > maxQ : q >= maxQ { return false }
        }
        if let minSC = query.minSampleCount {
            let sc = row.sampleCount ?? 0
            if query.minSampleCountInclusive ? sc < minSC : sc <= minSC { return false }
        }
        if let maxSC = query.maxSampleCount {
            let sc = row.sampleCount ?? Int.max
            if query.maxSampleCountInclusive ? sc > maxSC : sc >= maxSC { return false }
        }
        return true
    }
}

/// Pure moderate-or-higher impact filter (free function, safe to call from any thread).
func filterModerateOrHigherImpactOffMain(
    _ results: [AnnotationSearchIndex.SearchResult]
) -> [AnnotationSearchIndex.SearchResult] {
    let impactKeys = SmartToken.impactKeys
    return results.filter { result in
        guard let info = result.infoDict else { return false }
        for key in impactKeys {
            guard let raw = info[key], !raw.isEmpty else { continue }
            let value = raw.uppercased()
            if value.contains("HIGH") || value.contains("MODERATE") { return true }
        }
        return false
    }
}

/// Pure within-sample AF filter (free function, safe to call from any thread).
func filterByWithinSampleAFOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    min: Double, max: Double
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { result in
        guard let info = result.infoDict,
              let raw = info["AF"] ?? info["af"],
              !raw.isEmpty else { return false }
        let values = raw.split(separator: ",").compactMap { Double($0) }
        guard let af = values.max() else { return false }
        return af >= min && af <= max
    }
}

/// Pure viewport-region filter used after genome-wide queries.
func filterVariantsToRegionOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    chromosome: String,
    start: Int,
    end: Int
) -> [AnnotationSearchIndex.SearchResult] {
    let canonicalTargetChromosome = canonicalChromosomeForFiltering(chromosome)
    return results.filter { row in
        guard canonicalChromosomeForFiltering(row.chromosome) == canonicalTargetChromosome else { return false }
        return row.start <= end && row.end >= start
    }
}

private func canonicalChromosomeForFiltering(_ raw: String) -> String {
    var value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("chr") {
        value = String(value.dropFirst(3))
    }
    if let dot = value.firstIndex(of: ".") {
        value = String(value[..<dot])
    }
    return value
}
