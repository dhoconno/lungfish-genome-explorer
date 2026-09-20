import AppKit
import Foundation
import LungfishIO
import LungfishWorkflow

struct AnnotationTablePendingExport: @unchecked Sendable {
    let startedAt: Date
    let tab: String
    let scope: AnnotationTableExportScope
    let collect: @Sendable (@escaping @Sendable () -> Bool) throws -> AnnotationTableExportSnapshot
}

func validatedScientificTableExportSourceURLs(
    annotationDatabaseURLs: [URL],
    variantDatabaseURLs: [URL],
    overlaySourceURLs: [URL],
    additionalURLs: [URL]
) throws -> [URL] {
    let standardized = (
        annotationDatabaseURLs + variantDatabaseURLs + overlaySourceURLs + additionalURLs
    ).map(\.standardizedFileURL)
    if let missing = standardized.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
        throw AnnotationTableExportServiceError.missingScientificSource(missing)
    }
    var seen = Set<String>()
    let result = standardized.filter { seen.insert($0.path).inserted }
    guard !result.isEmpty else { throw AnnotationTableExportServiceError.noScientificSources }
    return result
}

extension AnnotationTableDrawerView {
    func captureScientificTableExport(scope: AnnotationTableExportScope) throws -> AnnotationTablePendingExport {
        let startedAt = Date()
        let columns = tableView.tableColumns.map {
            ScientificTableColumn(id: $0.identifier.rawValue, title: $0.title)
        }
        let selected = tableView.selectedRowIndexes
        let sources = try scientificTableExportSourceURLs()
        let numericInfoIDs = Set(infoColumnKeys.compactMap { info -> String? in
            let type = info.type.lowercased()
            return (type.contains("float") || type.contains("number") || type.contains("real"))
                ? "info_\(info.key)" : nil
        })
        let integerInfoIDs = Set(infoColumnKeys.compactMap { info -> String? in
            info.type.lowercased().contains("integer") ? "info_\(info.key)" : nil
        })
        let numericGenotypeInfoIDs = Set(numericInfoIDs.map { "gt\($0)" })
        let integerGenotypeInfoIDs = Set(integerInfoIDs.map { "gt\($0)" })
        let sortKey = tableView.sortDescriptors.first?.key
        let sortAscending = tableView.sortDescriptors.first?.ascending ?? true

        switch (activeTab, activeVariantSubtab, scope) {
        case (.annotations, _, .selected):
            let rows = selected.compactMap { displayedAnnotations.indices.contains($0) ? displayedAnnotations[$0] : nil }
            let resolved = resolvedAnnotationExportText(rows: rows, columns: columns)
            let snapshot = AnnotationTableExportSnapshot.captureAnnotations(
                rows, columns: columns, scope: scope, sourceURLs: sources,
                queryDescription: annotationExportQueryDescription(sortKey: sortKey, ascending: sortAscending),
                resolvedText: resolved
            )
            return pending(snapshot, startedAt: startedAt)

        case (.annotations, _, .allMatching):
            guard let index = searchIndex else { throw AnnotationTableExportServiceError.noScientificSources }
            let parsed = parseAnnotationFilterText(annotationFilterText.trimmingCharacters(in: .whitespacesAndNewlines))
            let visibleTypeFilter = visibleAnnotationTypes.count < availableAnnotationTypes.count ? visibleAnnotationTypes : []
            let mergedTypes: Set<String> = {
                guard let explicit = parsed.typeFilter, !explicit.isEmpty else { return visibleTypeFilter }
                return visibleTypeFilter.isEmpty ? explicit : visibleTypeFilter.intersection(explicit)
            }()
            let request = AnnotationTableAnnotationQueryRequest(
                databases: index.annotationDatabaseHandles.map {
                    ($0.trackId, $0.db.databaseURL, index.annotationTrackName(for: $0.trackId))
                },
                allowedChromosomes: allowedAnnotationChromosomes,
                nameFilter: parsed.nameFilter,
                types: mergedTypes,
                query: parsed,
                databaseColumnFilters: annotationDatabaseColumnFilters(),
                allColumnFilters: annotationColumnFilterClauses,
                numericSortKeys: Set(["start", "end", "size"] + annotationAttributeColumnKeys.compactMap {
                    isNumericAnnotationAttributeKey($0) ? "attr_\($0)" : nil
                }),
                sortKey: sortKey,
                sortAscending: sortAscending
            )
            let description = annotationExportQueryDescription(sortKey: sortKey, ascending: sortAscending)
            return AnnotationTablePendingExport(startedAt: startedAt, tab: "annotations", scope: scope) { shouldCancel in
                let rows = try request.run(shouldCancel: shouldCancel)
                return AnnotationTableExportSnapshot.captureAnnotations(
                    rows, columns: columns, scope: scope, sourceURLs: sources,
                    queryDescription: description
                )
            }

        case (.samples, _, _):
            let rows = scope == .selected
                ? selected.compactMap { displayedSamples.indices.contains($0) ? displayedSamples[$0] : nil }
                : displayedSamples
            let snapshot = AnnotationTableExportSnapshot.captureSamples(
                rows, columns: columns, scope: scope, sourceURLs: sources,
                queryDescription: sampleExportQueryDescription(sortKey: sortKey, ascending: sortAscending)
            )
            return pending(snapshot, startedAt: startedAt)

        case (.variants, .calls, .selected):
            let rows = selected.compactMap { displayedAnnotations.indices.contains($0) ? displayedAnnotations[$0] : nil }
            let snapshot = AnnotationTableExportSnapshot.captureVariants(
                rows, columns: columns, scope: scope, numericInfoColumnIDs: numericInfoIDs,
                integerInfoColumnIDs: integerInfoIDs,
                sourceURLs: sources,
                queryDescription: variantExportQueryDescription(sortKey: sortKey, ascending: sortAscending),
                resolvedText: resolvedVariantExportText(rows: rows, columns: columns)
            )
            return pending(snapshot, startedAt: startedAt)

        case (.variants, .calls, .allMatching):
            let request = try captureVariantAllMatchingRequest(sortKey: sortKey, ascending: sortAscending)
            var description = variantExportQueryDescription(sortKey: sortKey, ascending: sortAscending)
            description["resolvedRegion"] = request.region.map { "\($0.chromosome):\($0.start)-\($0.end)" } ?? "genome"
            description["resolvedGeneList"] = request.geneList?.joined(separator: ",") ?? "none"
            description["derivedVariantResolutionScope"] = "captured cached bundle CDS annotations with off-main reference preparation"
            description["derivedVariantFeatureCount"] = String(request.resolverSnapshot.features.count)
            let capturedDescription = description
            return AnnotationTablePendingExport(startedAt: startedAt, tab: "variants", scope: scope) { shouldCancel in
                let resolver = try request.resolverSnapshot.preparingForBackgroundExport(
                    shouldCancel: shouldCancel
                )
                let rows = try request.run(
                    shouldCancel: shouldCancel,
                    preparedResolverSnapshot: resolver
                )
                return AnnotationTableExportSnapshot.captureVariants(
                    rows, columns: columns, scope: scope, numericInfoColumnIDs: numericInfoIDs,
                    integerInfoColumnIDs: integerInfoIDs,
                    sourceURLs: sources, queryDescription: capturedDescription,
                    resolvedText: Self.backgroundVariantResolvedText(
                        rows: rows, columns: columns,
                        callerSettingsByTrack: request.callerSettingsByTrack,
                        resolverSnapshot: resolver
                    )
                )
            }

        case (.variants, .genotypes, .selected):
            let rows = selected.compactMap { displayedGenotypes.indices.contains($0) ? displayedGenotypes[$0] : nil }
            let snapshot = AnnotationTableExportSnapshot.captureGenotypes(
                rows, columns: columns, scope: scope, numericInfoColumnIDs: numericGenotypeInfoIDs,
                integerInfoColumnIDs: integerGenotypeInfoIDs,
                sourceURLs: sources,
                queryDescription: genotypeExportQueryDescription(sortKey: sortKey, ascending: sortAscending)
            )
            return pending(snapshot, startedAt: startedAt)

        case (.variants, .genotypes, .allMatching):
            let request = try captureVariantAllMatchingRequest(sortKey: nil, ascending: true)
            let databaseURLByTrack = Dictionary(uniqueKeysWithValues: request.context.databases.map { ($0.trackId, $0.db.databaseURL) })
            let hiddenSamples = currentSampleDisplayState.hiddenSamples
            let textFilter = variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            let clauses = genotypeColumnFilterClauses
            let numericGenotypeKeys = Set(["position", "dp", "gq", "ab"])
                .union(numericGenotypeInfoIDs)
                .union(integerGenotypeInfoIDs)
            var description = genotypeExportQueryDescription(sortKey: sortKey, ascending: sortAscending)
            description["resolvedRegion"] = request.region.map { "\($0.chromosome):\($0.start)-\($0.end)" } ?? "genome"
            description["resolvedGeneList"] = request.geneList?.joined(separator: ",") ?? "none"
            let capturedDescription = description
            return AnnotationTablePendingExport(startedAt: startedAt, tab: "genotypes", scope: scope) { shouldCancel in
                let variants = try request.run(shouldCancel: shouldCancel)
                var genotypeRows: [GenotypeDisplayRow] = []
                for (trackID, trackVariants) in Dictionary(grouping: variants, by: \.trackId) {
                    if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
                    guard let databaseURL = databaseURLByTrack[trackID] else { continue }
                    let database = try VariantDatabase(url: databaseURL)
                    database.installQueryTimeout(seconds: 30, cancelCheck: shouldCancel)
                    defer { database.removeQueryTimeout() }
                    let ids = trackVariants.compactMap(\.variantRowId)
                    let genotypes = try database.genotypesForExport(variantRowIds: ids)
                    let variantsByID = Dictionary(uniqueKeysWithValues: trackVariants.compactMap { row in
                        row.variantRowId.map { ($0, row) }
                    })
                    for id in ids {
                        guard let variant = variantsByID[id] else { continue }
                        for genotype in genotypes[id] ?? [] where !hiddenSamples.contains(genotype.sampleName) {
                            genotypeRows.append(GenotypeDisplayRow(
                                sampleName: genotype.sampleName, variantRowId: id,
                                variantID: variant.name, chromosome: variant.chromosome,
                                position: variant.start, ref: variant.ref ?? "", alt: variant.alt ?? "",
                                genotype: genotype.genotype ?? "./.",
                                zygosity: GenotypeDisplayRow.classify(allele1: genotype.allele1, allele2: genotype.allele2),
                                alleleDepths: genotype.alleleDepths ?? "", depth: genotype.depth,
                                genotypeQuality: genotype.genotypeQuality,
                                alleleBalance: GenotypeDisplayRow.computeAlleleBalance(from: genotype.alleleDepths),
                                infoDict: variant.infoDict ?? [:], trackId: trackID,
                                trackName: variant.trackName ?? trackID
                            ))
                        }
                    }
                }
                genotypeRows = Self.filterExportGenotypes(
                    genotypeRows, textFilter: textFilter, clauses: clauses,
                    numericKeys: numericGenotypeKeys
                )
                genotypeRows = Self.sortExportGenotypes(
                    genotypeRows, key: sortKey, ascending: sortAscending,
                    numericKeys: numericGenotypeKeys
                )
                return AnnotationTableExportSnapshot.captureGenotypes(
                    genotypeRows, columns: columns, scope: scope,
                    numericInfoColumnIDs: numericGenotypeInfoIDs,
                    integerInfoColumnIDs: integerGenotypeInfoIDs,
                    sourceURLs: sources, queryDescription: capturedDescription
                )
            }
        }
    }

    private func pending(_ snapshot: AnnotationTableExportSnapshot, startedAt: Date) -> AnnotationTablePendingExport {
        AnnotationTablePendingExport(startedAt: startedAt, tab: snapshot.tab, scope: snapshot.scope) { shouldCancel in
            if shouldCancel() { throw AnnotationTableExportQueryError.cancelled }
            return snapshot
        }
    }

    private func captureVariantAllMatchingRequest(
        sortKey: String?, ascending: Bool
    ) throws -> AnnotationTableVariantQueryRequest {
        guard let index = searchIndex else { throw AnnotationTableExportServiceError.noScientificSources }
        let parsed = parseVariantFilterText(variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines))
        let visibleTypes = visibleVariantTypes.count < availableVariantTypes.count ? visibleVariantTypes : []
        let composed = activeSmartTokens.composeFilters(infoKeys: Set(infoColumnKeys.map(\.key)))
        var types = visibleTypes
        for restriction in [parsed.explicitTypeFilter ?? [], composed.typeRestrictions] where !restriction.isEmpty {
            types = types.isEmpty ? restriction : types.intersection(restriction)
        }
        let presetFilters = selectedVariantPresetByKey.map {
            VariantDatabase.InfoFilter(key: $0.key, op: .eq, value: $0.value)
        }
        let projectedColumnFilters = variantColumnFilterClauses.compactMap { clause -> VariantDatabase.InfoFilter? in
            guard clause.key.hasPrefix("info_") else { return nil }
            let key = String(clause.key.dropFirst(5))
            guard index.variantFormatOverlaySnapshot.allProjectedKeys.contains(key) else { return nil }
            let op: VariantDatabase.InfoFilter.ComparisonOp
            switch clause.op {
            case ">": op = .gt; case ">=": op = .gte; case "<": op = .lt; case "<=": op = .lte
            case "=": op = .eq; case "!=": op = .neq; default: op = .like
            }
            return .init(key: key, op: op, value: clause.value)
        }
        var query = parsed
        query.infoFilters += presetFilters + composed.infoFilters + projectedColumnFilters
        if query.minQuality == nil, let quality = composed.minQuality {
            query.minQuality = quality
            query.minQualityInclusive = true
        }
        if query.filterValue == nil { query.filterValue = composed.filterValue }
        let geneList = query.geneList ?? detectGeneListPattern(query.nameFilter)
        let hasGlobalOverride = hasActiveSearchFilters && query.region == nil
        let viewportPostFilter = hasGlobalOverride && viewportSyncEnabled && allowViewportPostFilterDuringExploration
            ? viewportRegion : nil
        let region: (chromosome: String, start: Int, end: Int)?
        if geneList != nil {
            region = nil
        } else if let viewportPostFilter {
            region = viewportPostFilter
        } else if hasGlobalOverride {
            region = nil
        } else if let queryRegion = query.region {
            region = queryRegion
        } else if let selectedAnnotationRegion {
            region = selectedAnnotationRegion
        } else if isViewportSyncActive {
            region = viewportRegion
        } else if viewportSyncEnabled {
            region = annotationSearchRegion
        } else {
            region = query.region
        }
        let trackNames = Dictionary(uniqueKeysWithValues: index.variantDatabaseHandles.map {
            ($0.trackId, index.variantTrackName(for: $0.trackId) ?? $0.trackId)
        })
        let context = AnnotationVariantQueryContext(
            databases: index.variantDatabaseHandles,
            trackNames: trackNames,
            trackChromosomes: index.variantTrackChromosomeMap,
            annotationDatabases: index.annotationDatabaseHandles,
            infoKeys: Set(infoColumnKeys.map(\.key)),
            variantAliasMap: variantChromosomeAliasMap,
            formatOverlay: index.variantFormatOverlaySnapshot
        )
        return AnnotationTableVariantQueryRequest(
            context: context, query: query, types: types, infoFilters: query.infoFilters,
            selectedSamples: selectedSamplesForVariantQuery(),
            activeTokens: Set(activeSmartTokens.map(\.rawValue)), region: region,
            geneList: geneList,
            filterBookmarkedOnly: composed.postFilters.contains { if case .bookmarkedOnly = $0 { return true }; return false },
            filterModerateOrHigher: composed.postFilters.contains { if case .moderateOrHigherImpact = $0 { return true }; return false },
            withinSampleAFRange: composed.postFilters.compactMap { if case .withinSampleAFRange(let min, let max) = $0 { return (min, max) }; return nil }.first,
            bookmarkedKeys: bookmarkedVariantKeys, hiddenTrackIDs: hiddenVariantTrackIDs,
            variantColumnFilters: variantColumnFilterClauses,
            callerSettingsByTrack: Dictionary(uniqueKeysWithValues: index.variantDatabaseHandles.map {
                ($0.trackId, index.variantCallerSettings(for: $0.trackId))
            }),
            resolverSnapshot: delegate?.annotationDrawerVariantExportResolverSnapshot(self) ?? .empty,
            numericColumnKeys: Set(["position", "quality", "samples"] + infoColumnKeys.compactMap {
                let type = $0.type.lowercased()
                return (type.contains("integer") || type.contains("float") || type.contains("number")) ? "info_\($0.key)" : nil
            }),
            sortKey: sortKey, sortAscending: ascending
        )
    }

    private func scientificTableExportSourceURLs() throws -> [URL] {
        guard let index = searchIndex else { throw AnnotationTableExportServiceError.noScientificSources }
        return try validatedScientificTableExportSourceURLs(
            annotationDatabaseURLs: index.annotationDatabaseHandles.map { $0.db.databaseURL },
            variantDatabaseURLs: index.variantDatabaseHandles.map { $0.db.databaseURL },
            overlaySourceURLs: index.variantFormatOverlaySnapshot.sourceIdentities.map(\.url),
            additionalURLs: activeTab == .variants
                ? (try delegate?.annotationDrawerAdditionalExportSources(self) ?? []) : []
        )
    }

    private func resolvedAnnotationExportText(
        rows: [AnnotationSearchIndex.SearchResult], columns: [ScientificTableColumn]
    ) -> [String: [String: String]] { [:] }

    private func resolvedVariantExportText(
        rows: [AnnotationSearchIndex.SearchResult], columns: [ScientificTableColumn]
    ) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            let identity = "\(row.trackId):\(row.variantRowId.map(String.init) ?? row.id.uuidString)"
            return (identity, Dictionary(uniqueKeysWithValues: columns.map { column in
                (column.id, cellValueForScientificVariantColumn(column.id, row: row))
            }))
        })
    }

    private func cellValueForScientificVariantColumn(
        _ columnID: String, row: AnnotationSearchIndex.SearchResult
    ) -> String {
        switch columnID {
        case Self.callerSettingsColumn.rawValue: return searchIndex?.variantCallerSettings(for: row.trackId) ?? "Not recorded"
        case Self.codingFeatureColumn.rawValue: return variantCodingFeatureText(for: row)
        case Self.consequenceColumn.rawValue: return variantConsequenceText(for: row)
        case Self.aaChangeColumn.rawValue: return variantAAChangeText(for: row)
        default: return ""
        }
    }

    nonisolated static func backgroundVariantResolvedText(
        rows: [AnnotationSearchIndex.SearchResult], columns: [ScientificTableColumn],
        callerSettingsByTrack: [String: String],
        resolverSnapshot: VariantTableExportResolverSnapshot
    ) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            let resolved = resolverSnapshot.resolve(row)
            let identity = "\(row.trackId):\(row.variantRowId.map(String.init) ?? row.id.uuidString)"
            let values = Dictionary(uniqueKeysWithValues: columns.map { column -> (String, String) in
                let value: String
                switch column.id {
                case Self.callerSettingsColumn.rawValue:
                    value = callerSettingsByTrack[row.trackId] ?? "Not recorded"
                case Self.codingFeatureColumn.rawValue:
                    value = resolved.codingFeature
                case Self.consequenceColumn.rawValue:
                    value = resolved.consequence
                case Self.aaChangeColumn.rawValue:
                    value = resolved.aaChange
                default: value = ""
                }
                return (column.id, value)
            })
            return (identity, values)
        })
    }

    private func annotationExportQueryDescription(sortKey: String?, ascending: Bool) -> [String: String] {
        ["text": annotationFilterText, "types": visibleAnnotationTypes.sorted().joined(separator: ","),
         "allowedChromosomes": allowedAnnotationChromosomes?.sorted().joined(separator: ",") ?? "all",
         "columnFilters": annotationColumnFilterClauses.map { "\($0.key)\($0.op)\($0.value)" }.joined(separator: ";"),
         "sort": "\(sortKey ?? "database-default"):\(ascending ? "ascending" : "descending")"]
    }

    private func variantExportQueryDescription(sortKey: String?, ascending: Bool) -> [String: String] {
        ["text": variantFilterText, "types": visibleVariantTypes.sorted().joined(separator: ","),
         "tokens": activeSmartTokens.map(\.rawValue).sorted().joined(separator: ","),
         "presets": selectedVariantPresetByKey.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";"),
         "hiddenTracks": hiddenVariantTrackIDs.sorted().joined(separator: ","),
         "hiddenSamples": currentSampleDisplayState.hiddenSamples.sorted().joined(separator: ","),
         "selectedSamples": selectedSamplesForVariantQuery().sorted().joined(separator: ","),
         "bookmarkIdentities": bookmarkedVariantKeys.sorted().joined(separator: ","),
         "overlaySources": searchIndex?.variantFormatOverlaySnapshot.sourceIdentities.map(\.url.path).sorted().joined(separator: ",") ?? "",
         "columnFilters": variantColumnFilterClauses.map { "\($0.key)\($0.op)\($0.value)" }.joined(separator: ";"),
         "sort": "\(sortKey ?? "database-default"):\(ascending ? "ascending" : "descending")"]
    }

    private func genotypeExportQueryDescription(sortKey: String?, ascending: Bool) -> [String: String] {
        var result = variantExportQueryDescription(sortKey: sortKey, ascending: ascending)
        result["genotypeColumnFilters"] = genotypeColumnFilterClauses.map { "\($0.key)\($0.op)\($0.value)" }.joined(separator: ";")
        return result
    }

    private func sampleExportQueryDescription(sortKey: String?, ascending: Bool) -> [String: String] {
        ["text": sampleFilterText, "tokens": activeSampleTokens.map(\.rawValue).sorted().joined(separator: ","),
         "sampleGroup": selectedSampleGroupId?.uuidString ?? "all",
         "sort": "\(sortKey ?? "current-order"):\(ascending ? "ascending" : "descending")"]
    }

    nonisolated private static func filterExportGenotypes(
        _ rows: [GenotypeDisplayRow], textFilter: String,
        clauses: [VariantColumnFilterClause], numericKeys: Set<String>
    ) -> [GenotypeDisplayRow] {
        let needle = textFilter.lowercased()
        return rows.filter { row in
            let textMatches = needle.isEmpty || [row.sampleName, row.trackName, row.zygosity, row.genotype, row.variantID, row.chromosome]
                .contains { $0.lowercased().contains(needle) }
            return textMatches && clauses.allSatisfy { clause in
                let value = exportGenotypeValue(row, key: clause.key)
                if numericKeys.contains(clause.key),
                   let lhs = Double(value), let rhs = Double(clause.value) {
                    switch clause.op { case ">": return lhs > rhs; case ">=": return lhs >= rhs; case "<": return lhs < rhs; case "<=": return lhs <= rhs; default: break }
                }
                return textColumnMatchesOffMain(actual: value, op: clause.op, expected: clause.value)
            }
        }
    }

    nonisolated private static func sortExportGenotypes(
        _ rows: [GenotypeDisplayRow], key: String?, ascending: Bool,
        numericKeys: Set<String>
    ) -> [GenotypeDisplayRow] {
        guard let key else { return rows }
        return rows.sorted { leftRow, rightRow in
            let left = exportGenotypeValue(leftRow, key: key)
            let right = exportGenotypeValue(rightRow, key: key)
            let comparison: ComparisonResult
            if numericKeys.contains(key), let lhs = Double(left), let rhs = Double(right) {
                comparison = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
            } else {
                comparison = left.localizedCaseInsensitiveCompare(right)
            }
            if comparison == .orderedSame {
                let lhs = "\(leftRow.trackId):\(leftRow.variantRowId):\(leftRow.sampleName)"
                let rhs = "\(rightRow.trackId):\(rightRow.variantRowId):\(rightRow.sampleName)"
                return ascending ? lhs < rhs : lhs > rhs
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    nonisolated private static func exportGenotypeValue(_ row: GenotypeDisplayRow, key: String) -> String {
        switch key {
        case "sample": return row.sampleName; case "track": return row.trackName; case "variant": return row.variantID
        case "chromosome": return row.chromosome; case "position": return String(row.position + 1)
        case "genotype": return row.genotype; case "zygosity": return row.zygosity; case "ad": return row.alleleDepths
        case "dp": return row.depth.map { String($0) } ?? ""; case "gq": return row.genotypeQuality.map { String($0) } ?? ""
        case "ab": return row.alleleBalance.map { String($0) } ?? ""
        default: return key.hasPrefix("gtinfo_") ? row.infoDict[String(key.dropFirst(7))] ?? "" : ""
        }
    }
}
