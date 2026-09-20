import Foundation
import LungfishIO

enum AnnotationTableExportQueryError: LocalizedError {
    case cancelled
    case incomplete(expectedAtMost: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The table export query was cancelled."
        case .incomplete(let expected, let received):
            return "The table export query was incomplete (expected at most \(expected) source rows, received \(received))."
        }
    }
}

struct AnnotationTableAnnotationQueryRequest: @unchecked Sendable {
    let databases: [(trackID: String, url: URL, trackName: String?)]
    let allowedChromosomes: Set<String>?
    let nameFilter: String
    let types: Set<String>
    let query: AnnotationTableDrawerView.AnnotationFilterQuery
    let databaseColumnFilters: [AnnotationDatabase.ColumnFilterClause]
    let allColumnFilters: [AnnotationTableDrawerView.ColumnFilterClause]
    let numericSortKeys: Set<String>
    let sortKey: String?
    let sortAscending: Bool

    func run(shouldCancel: @escaping @Sendable () -> Bool) throws -> [AnnotationSearchIndex.SearchResult] {
        if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
        if allowedChromosomes?.isEmpty == true { return [] }
        var rows: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
            let database = try AnnotationDatabase(url: handle.url)
            database.installExportQueryTimeout(seconds: 30, cancelCheck: shouldCancel)
            defer { database.removeExportQueryTimeout() }
            let records: [AnnotationDatabaseRecord]
            do {
                records = try database.queryForTableExport(
                    nameFilter: nameFilter, types: types,
                    chromosome: query.chromosome, regionStart: query.start, regionEnd: query.end,
                    strand: query.strand, columnFilters: databaseColumnFilters,
                    allowedChromosomes: allowedChromosomes, limit: Int.max
                )
            } catch where shouldCancel() {
                throw AnnotationTableExportQueryError.cancelled
            }
            if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
            rows.append(contentsOf: records.map { record in
                AnnotationSearchIndex.SearchResult(
                    name: record.name, chromosome: record.chromosome,
                    start: record.start, end: record.end, trackId: handle.trackID,
                    trackName: handle.trackName, type: record.type, strand: record.strand,
                    attributes: record.attributes.map(AnnotationDatabase.parseAttributes),
                    annotationRowId: record.rowID
                )
            })
        }
        rows = applyAnnotationAdvancedFiltersOffMain(rows, query: query)
        rows = applyAnnotationColumnFiltersOffMain(to: rows, clauses: allColumnFilters)
        return sortAnnotationRows(
            rows, key: sortKey, ascending: sortAscending,
            numericKeys: numericSortKeys
        )
    }
}

struct AnnotationTableVariantQueryRequest: @unchecked Sendable {
    let context: AnnotationVariantQueryContext
    let query: AnnotationTableDrawerView.VariantFilterQuery
    let types: Set<String>
    let infoFilters: [VariantDatabase.InfoFilter]
    let selectedSamples: Set<String>
    let activeTokens: Set<String>
    let region: (chromosome: String, start: Int, end: Int)?
    let geneList: [String]?
    let filterBookmarkedOnly: Bool
    let filterModerateOrHigher: Bool
    let withinSampleAFRange: (min: Double, max: Double)?
    let bookmarkedKeys: Set<String>
    let hiddenTrackIDs: Set<String>
    let variantColumnFilters: [AnnotationTableDrawerView.VariantColumnFilterClause]
    let callerSettingsByTrack: [String: String]
    let resolverSnapshot: VariantTableExportResolverSnapshot
    let numericColumnKeys: Set<String>
    let sortKey: String?
    let sortAscending: Bool

    func run(
        shouldCancel: @escaping @Sendable () -> Bool,
        preparedResolverSnapshot: VariantTableExportResolverSnapshot? = nil
    ) throws -> [AnnotationSearchIndex.SearchResult] {
        if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
        let resolver: VariantTableExportResolverSnapshot
        if let preparedResolverSnapshot {
            resolver = preparedResolverSnapshot
        } else {
            resolver = try resolverSnapshot.preparingForBackgroundExport(
                shouldCancel: shouldCancel
            )
        }
        var rows: [AnnotationSearchIndex.SearchResult] = []
        for handle in context.databases where !hiddenTrackIDs.contains(handle.trackId) {
            if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
            let database = try VariantDatabase(url: handle.db.databaseURL)
            let projectedKeys = context.formatOverlay.projectedKeysByTrack[handle.trackId] ?? []
            let deferredInfo = infoFilters.filter { projectedKeys.contains($0.key) }
            let sqlInfo = infoFilters.filter { !projectedKeys.contains($0.key) }
            let defersSmartAF = projectedKeys.contains("AF") && query.smartFilter?.predicates.contains { predicate in
                switch predicate {
                case .sample(let value): return value.field == .alleleFrequency
                case .count(let value): return value.predicate.field == .alleleFrequency
                case .sampleFieldComparison(let value): return value.lhs.field == .alleleFrequency
                }
            } == true
            database.installQueryTimeout(seconds: 30, cancelCheck: shouldCancel)
            defer { database.removeQueryTimeout() }
            let records = try database.queryForTableExport(
                nameFilter: geneList == nil ? query.nameFilter : "",
                types: types,
                infoFilters: sqlInfo,
                sampleNames: selectedSamples,
                smartFilter: defersSmartAF ? nil : query.smartFilter,
                activeTokens: deferredInfo.isEmpty && !defersSmartAF ? activeTokens : [],
                limit: Int.max
            )
            let infoByID = try database.batchInfoValuesForExport(variantIds: records.compactMap(\.id))
            let converted = records.map { record -> AnnotationSearchIndex.SearchResult in
                let stored = record.id.flatMap { infoByID[$0] } ?? [:]
                let projected = context.formatOverlay.projectedInfo(
                    trackID: handle.trackId, record: record, existing: stored
                )
                return record.toSearchResult(
                    trackId: handle.trackId, infoDict: projected,
                    sourceFile: context.trackNames[handle.trackId]
                )
            }
            rows.append(contentsOf: converted.filter { row in
                deferredInfo.allSatisfy { VariantFormatOverlaySnapshot.matches(row.infoDict ?? [:], filter: $0) }
                    && (!defersSmartAF || query.smartFilter.map {
                        context.formatOverlay.matches($0, trackID: handle.trackId, row: row)
                    } == true)
            })
        }
        if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
        if let region {
            rows = rows.filter { row in
                context.resolvedChromosomeCandidates(for: region.chromosome, trackId: row.trackId).contains(row.chromosome)
                    && row.start < region.end && row.end > region.start
            }
        }
        if let geneList, !geneList.isEmpty {
            let normalized = Set(geneList.map { $0.lowercased() })
            let keys = ["GENE", "Gene", "gene", "GENEINFO", "SYMBOL", "ANN_Gene", "CSQ_SYMBOL"]
            var regions: [(chromosome: String, start: Int, end: Int)] = []
            for gene in geneList {
                var candidates: [AnnotationDatabaseRecord] = []
                for handle in context.annotationDatabases {
                    if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
                    let database = try AnnotationDatabase(url: handle.db.databaseURL)
                    database.installExportQueryTimeout(seconds: 30, cancelCheck: shouldCancel)
                    defer { database.removeExportQueryTimeout() }
                    candidates.append(contentsOf: try database.queryForTableExport(
                        nameFilter: gene, limit: Int.max
                    ))
                }
                let needle = gene.lowercased()
                if let best = candidates.min(by: { left, right in
                    geneCandidateScore(left, needle: needle) < geneCandidateScore(right, needle: needle)
                }) {
                    regions.append((best.chromosome, best.start, best.end))
                }
            }
            rows = rows.filter { row in
                let inRegion = regions.contains {
                    context.resolvedChromosomeCandidates(for: $0.chromosome, trackId: row.trackId).contains(row.chromosome)
                        && row.start < $0.end && row.end > $0.start
                }
                let inInfo = keys.contains { key in
                    guard let value = row.infoDict?[key]?.lowercased() else { return false }
                    return normalized.contains { value.contains($0) }
                }
                return inRegion || inInfo
            }
        }
        rows = applyVariantAdvancedFiltersOffMain(rows, query: query)
        if filterModerateOrHigher { rows = filterModerateOrHigherImpactOffMain(rows) }
        if filterBookmarkedOnly {
            rows = rows.filter { row in
                row.variantRowId.map { bookmarkedKeys.contains("\(row.trackId):\($0)") } == true
            }
        }
        if let range = withinSampleAFRange {
            rows = filterByWithinSampleAFOffMain(rows, min: range.min, max: range.max)
        }
        let derivedKeys: Set<String> = ["coding_feature", "consequence", "aa_change"]
        let needsDerivedValues = variantColumnFilters.contains { derivedKeys.contains($0.key) }
            || sortKey.map { derivedKeys.contains($0) } == true
        let resolvedByIdentity: [String: VariantTableExportResolvedFields] = needsDerivedValues
            ? Dictionary(uniqueKeysWithValues: rows.map { row in
                (variantExportIdentity(row), resolver.resolve(row))
            })
            : [:]
        rows = rows.filter { row in
            variantColumnFilters.allSatisfy { clause in
                tableVariantColumnMatches(
                    row: row, clause: clause,
                    numericColumnKeys: numericColumnKeys,
                    callerSettingsByTrack: callerSettingsByTrack,
                    resolverSnapshot: resolver,
                    resolvedFields: resolvedByIdentity[variantExportIdentity(row)]
                )
            }
        }
        return sortVariantRows(
            rows, key: sortKey, ascending: sortAscending,
            numericColumnKeys: numericColumnKeys,
            callerSettingsByTrack: callerSettingsByTrack,
            resolverSnapshot: resolver,
            resolvedByIdentity: resolvedByIdentity
        )
    }
}

private func geneCandidateScore(_ row: AnnotationDatabaseRecord, needle: String) -> (Int, Int, Int, String, Int) {
    let name = row.name.lowercased()
    let nameScore = name == needle ? 0 : (name.hasPrefix(needle) ? 1 : (name.contains(needle) ? 2 : 3))
    let preferred = ["gene", "mrna", "transcript", "cds", "exon"]
    let typeScore = preferred.firstIndex(of: row.type.lowercased()) ?? preferred.count + 1
    return (nameScore, typeScore, max(0, row.end - row.start), row.chromosome, row.start)
}

private func sortAnnotationRows(
    _ rows: [AnnotationSearchIndex.SearchResult], key: String?, ascending: Bool,
    numericKeys: Set<String>
) -> [AnnotationSearchIndex.SearchResult] {
    guard let key else { return rows }
    return rows.sorted { left, right in
        let comparison: ComparisonResult
        let leftValue = annotationColumnValueOffMain(left, key: key)
        let rightValue = annotationColumnValueOffMain(right, key: key)
        if numericKeys.contains(key), let lhs = Double(leftValue), let rhs = Double(rightValue) {
            comparison = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        } else {
            comparison = leftValue.localizedCaseInsensitiveCompare(rightValue)
        }
        if comparison == .orderedSame {
            let lhs = "\(left.trackId):\(left.annotationRowId.map(String.init) ?? left.id.uuidString)"
            let rhs = "\(right.trackId):\(right.annotationRowId.map(String.init) ?? right.id.uuidString)"
            return ascending ? lhs < rhs : lhs > rhs
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}

private func sortVariantRows(
    _ rows: [AnnotationSearchIndex.SearchResult], key: String?, ascending: Bool,
    numericColumnKeys: Set<String>, callerSettingsByTrack: [String: String],
    resolverSnapshot: VariantTableExportResolverSnapshot,
    resolvedByIdentity: [String: VariantTableExportResolvedFields]
) -> [AnnotationSearchIndex.SearchResult] {
    guard let key else { return rows }
    return rows.sorted { left, right in
        let l = tableVariantColumnValue(
            row: left, key: key, callerSettingsByTrack: callerSettingsByTrack,
            resolverSnapshot: resolverSnapshot,
            resolvedFields: resolvedByIdentity[variantExportIdentity(left)]
        )
        let r = tableVariantColumnValue(
            row: right, key: key, callerSettingsByTrack: callerSettingsByTrack,
            resolverSnapshot: resolverSnapshot,
            resolvedFields: resolvedByIdentity[variantExportIdentity(right)]
        )
        let comparison: ComparisonResult
        if numericColumnKeys.contains(key), let ln = Double(l), let rn = Double(r) {
            comparison = ln == rn ? .orderedSame : (ln < rn ? .orderedAscending : .orderedDescending)
        } else {
            comparison = l.localizedCaseInsensitiveCompare(r)
        }
        if comparison == .orderedSame {
            let leftIdentity = "\(left.trackId):\(left.variantRowId.map(String.init) ?? left.id.uuidString)"
            let rightIdentity = "\(right.trackId):\(right.variantRowId.map(String.init) ?? right.id.uuidString)"
            return ascending ? leftIdentity < rightIdentity : leftIdentity > rightIdentity
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}

func tableVariantColumnMatches(
    row: AnnotationSearchIndex.SearchResult,
    clause: AnnotationTableDrawerView.VariantColumnFilterClause,
    numericColumnKeys: Set<String>,
    callerSettingsByTrack: [String: String],
    resolverSnapshot: VariantTableExportResolverSnapshot = .empty,
    resolvedFields: VariantTableExportResolvedFields? = nil
) -> Bool {
    let actual = tableVariantColumnValue(
        row: row, key: clause.key, callerSettingsByTrack: callerSettingsByTrack,
        resolverSnapshot: resolverSnapshot,
        resolvedFields: resolvedFields
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = clause.value.trimmingCharacters(in: .whitespacesAndNewlines)
    if numericColumnKeys.contains(clause.key) {
        if let lhs = Double(actual), let rhs = Double(expected) {
            switch clause.op {
            case ">": return lhs > rhs
            case ">=": return lhs >= rhs
            case "<": return lhs < rhs
            case "<=": return lhs <= rhs
            case "=": return lhs == rhs
            case "!=": return lhs != rhs
            default: break
            }
        }
    }
    return textColumnMatchesOffMain(actual: actual, op: clause.op, expected: expected)
}

func tableVariantColumnValue(
    row: AnnotationSearchIndex.SearchResult,
    key: String,
    callerSettingsByTrack: [String: String] = [:],
    resolverSnapshot: VariantTableExportResolverSnapshot = .empty,
    resolvedFields: VariantTableExportResolvedFields? = nil
) -> String {
    switch key {
    case "variant_id", "name": return row.name
    case "variant_type", "type": return row.type
    case "chromosome": return row.chromosome
    case "position": return String(row.start + 1)
    case "ref": return row.ref ?? ""
    case "alt": return row.alt ?? ""
    case "quality": return row.quality.map { String($0) } ?? ""
    case "filter": return row.filter ?? ""
    case "samples": return row.sampleCount.map(String.init) ?? ""
    case "source": return row.sourceFile ?? ""
    case "track_id": return row.trackId
    case "track_name": return row.trackName ?? row.trackId
    case "caller_settings": return callerSettingsByTrack[row.trackId] ?? "Not recorded"
    case "coding_feature": return (resolvedFields ?? resolverSnapshot.resolve(row)).codingFeature
    case "consequence": return (resolvedFields ?? resolverSnapshot.resolve(row)).consequence
    case "aa_change": return (resolvedFields ?? resolverSnapshot.resolve(row)).aaChange
    default:
        if key.hasPrefix("info_") { return row.infoDict?[String(key.dropFirst(5))] ?? "" }
        return ""
    }
}

private func variantExportIdentity(_ row: AnnotationSearchIndex.SearchResult) -> String {
    "\(row.trackId):\(row.variantRowId.map(String.init) ?? row.id.uuidString)"
}
