// AnnotationTableDrawerView+Filtering.swift - Extracted from AnnotationTableDrawerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import os.log

extension AnnotationTableDrawerView {

    // MARK: - Filtering

    func updateDisplayedAnnotations() {
        if activeTab == .variants {
            enforceMaterializedOnlyRestrictionsIfNeeded()
        } else if activeTab == .annotations {
            invalidatePendingAnnotationQuery()
            #if DEBUG
            debugAnnotationQueryExecutionCount += 1
            #endif
        }

        let currentFilterText: String = switch activeTab {
        case .annotations: annotationFilterText
        case .variants: variantFilterText
        case .samples: sampleFilterText
        }

        // Build the type filter set — only pass types if not all are selected
        let typeFilter: Set<String> = visibleTypes.count < availableTypes.count ? visibleTypes : []

        let entityName = activeTab == .annotations ? "annotations" : "variants"
        let activeTotal = activeTab == .annotations ? totalAnnotationCount : totalVariantCount

        // Parse tab-specific advanced search expressions.
        let annotationQuery = parseAnnotationFilterText(currentFilterText)
        let variantQuery = parseVariantFilterText(currentFilterText)
        let nameFilter = activeTab == .annotations ? annotationQuery.nameFilter : variantQuery.nameFilter

        // SQLite mode: query the database directly with filters
        if let index = searchIndex, (index.hasDatabaseBackend || index.hasVariantDatabase) {
            if activeTab == .variants {
                updateDisplayedVariants(index: index, typeFilter: typeFilter, query: variantQuery)
                // Count label is updated by the async completion callback.
                return
            }

            // Annotations tab: global query
            let mergedTypeFilter: Set<String> = {
                guard let explicitType = annotationQuery.typeFilter, !explicitType.isEmpty else { return typeFilter }
                if typeFilter.isEmpty { return explicitType }
                return typeFilter.intersection(explicitType)
            }()
            let databaseColumnFilters = annotationDatabaseColumnFilters()
            let hasNarrowingFilter = !nameFilter.isEmpty
                || !mergedTypeFilter.isEmpty
                || annotationQuery.chromosome != nil
                || annotationQuery.start != nil
                || annotationQuery.end != nil
                || annotationQuery.strand != nil
                || !annotationColumnFilterClauses.isEmpty

            if !hasNarrowingFilter && activeTotal > Self.maxDisplayCount {
                setAnnotationBaseResults([])
                tableView.reloadData()
                scrollView.isHidden = false
                let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) \(entityName) — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
                annotationSearchRegion = nil
            } else if !hasNarrowingFilter {
                let filtered = fetchAnnotationRowsForDisplay(
                    index: index,
                    nameFilter: nameFilter,
                    typeFilter: mergedTypeFilter,
                    query: annotationQuery,
                    databaseColumnFilters: databaseColumnFilters,
                    requiresPostOnlyColumnFiltering: false
                )
                setAnnotationBaseResults(filtered)
                tableView.reloadData()
                scrollView.isHidden = false
                tooManyLabel.isHidden = true
                updateAnnotationSearchRegion()
            } else {
                let allColumnFilters = annotationColumnFilterClauses
                let requiresPostOnlyColumnFiltering = hasPostOnlyAnnotationColumnFilters()
                let maxDisplay = Self.maxDisplayCount
                let generation = annotationQueryGeneration
                var trackNames: [String: String] = [:]
                for handle in index.annotationDatabaseHandles {
                    if let name = index.annotationTrackName(for: handle.trackId) {
                        trackNames[handle.trackId] = name
                    }
                }
                let context = AnnotationQueryContext(
                    databases: index.annotationDatabaseHandles.map {
                        (trackId: $0.trackId, databaseURL: $0.db.databaseURL)
                    },
                    trackNames: trackNames
                )
                let cancelToken = VariantQueryCancellationToken()
                activeAnnotationQueryCancelToken = cancelToken

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let filtered = fetchAnnotationRowsForDisplayOffMain(
                        context: context,
                        nameFilter: nameFilter,
                        typeFilter: mergedTypeFilter,
                        query: annotationQuery,
                        databaseColumnFilters: databaseColumnFilters,
                        allColumnFilters: allColumnFilters,
                        requiresPostOnlyColumnFiltering: requiresPostOnlyColumnFiltering,
                        maxDisplayCount: maxDisplay,
                        shouldCancel: { cancelToken.isCancelled }
                    )

                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self,
                                  self.activeAnnotationQueryCancelToken === cancelToken,
                                  self.annotationQueryGeneration == generation,
                                  self.activeTab == .annotations else { return }
                            self.activeAnnotationQueryCancelToken = nil
                            if filtered.count > maxDisplay {
                                self.setAnnotationBaseResults([])
                                self.tableView.reloadData()
                                self.scrollView.isHidden = false
                                let max = self.numberFormatter.string(from: NSNumber(value: maxDisplay)) ?? "\(maxDisplay)"
                                self.tooManyLabel.stringValue = "\(max)+ \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                                self.tooManyLabel.isHidden = false
                                self.annotationSearchRegion = nil
                            } else {
                                self.setAnnotationBaseResults(filtered)
                                self.tableView.reloadData()
                                self.scrollView.isHidden = false
                                self.tooManyLabel.isHidden = true
                                self.updateAnnotationSearchRegion()
                            }
                            self.updateCountLabel()
                        }
                    }
                }
                return
            }
            updateCountLabel()
            return
        }

        // Legacy in-memory mode (annotations only — variants always need SQLite)
        if let index = searchIndex, activeTab == .annotations {
            let hasFilters = !typeFilter.isEmpty || !nameFilter.isEmpty

            if !hasFilters && activeTotal > Self.maxDisplayCount {
                setAnnotationBaseResults([])
                tableView.reloadData()
                scrollView.isHidden = false
                let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) \(entityName) — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                var results = index.allResults
                if !typeFilter.isEmpty {
                    results = results.filter { typeFilter.contains($0.type) }
                }
                if !nameFilter.isEmpty {
                    let lower = nameFilter.lowercased()
                    results = results.filter { $0.name.lowercased().contains(lower) }
                }
                if results.count > Self.maxDisplayCount {
                    setAnnotationBaseResults([])
                    tableView.reloadData()
                    scrollView.isHidden = false
                    let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
                    let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                    tooManyLabel.stringValue = "\(total) \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                    tooManyLabel.isHidden = false
                } else {
                    setAnnotationBaseResults(results)
                    tableView.reloadData()
                    scrollView.isHidden = false
                    tooManyLabel.isHidden = true
                }
            }
        } else if activeTab == .variants {
            // No variant data in legacy mode
            displayedAnnotations = []
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
        }
        updateCountLabel()
    }

    func annotationDatabaseColumnFilters() -> [AnnotationDatabase.ColumnFilterClause] {
        annotationColumnFilterClauses
            .filter { isAnnotationDatabasePushdownColumnFilter($0.key) }
            .map {
            AnnotationDatabase.ColumnFilterClause(key: $0.key, op: $0.op, value: $0.value)
        }
    }

    func hasPostOnlyAnnotationColumnFilters() -> Bool {
        annotationColumnFilterClauses.contains { !isAnnotationDatabasePushdownColumnFilter($0.key) }
    }

    func isAnnotationDatabasePushdownColumnFilter(_ key: String) -> Bool {
        switch key {
        case "name", "track_id", "track_name", "type", "chromosome", "start", "end", "size", "strand":
            return true
        default:
            return false
        }
    }

    func fetchAnnotationRowsForDisplay(
        index: AnnotationSearchIndex,
        nameFilter: String,
        typeFilter: Set<String>,
        query annotationQuery: AnnotationFilterQuery,
        databaseColumnFilters: [AnnotationDatabase.ColumnFilterClause],
        requiresPostOnlyColumnFiltering: Bool
    ) -> [AnnotationSearchIndex.SearchResult] {
        let targetCount = Self.maxDisplayCount + 1
        var fetchLimit = targetCount

        while true {
            let results = index.queryAnnotationsOnly(
                nameFilter: nameFilter,
                types: typeFilter,
                chromosome: annotationQuery.chromosome,
                regionStart: annotationQuery.start,
                regionEnd: annotationQuery.end,
                strand: annotationQuery.strand,
                columnFilters: databaseColumnFilters,
                limit: fetchLimit
            )
            let filtered = applyAnnotationColumnFilters(
                to: applyAnnotationAdvancedFilters(results, query: annotationQuery)
            )

            if !requiresPostOnlyColumnFiltering
                || filtered.count >= targetCount
                || results.count < fetchLimit {
                return Array(filtered.prefix(targetCount))
            }

            fetchLimit = max(fetchLimit * 2, fetchLimit + targetCount)
        }
    }

    func invalidatePendingAnnotationQuery() {
        annotationQueryWorkItem?.cancel()
        annotationQueryWorkItem = nil
        activeAnnotationQueryCancelToken?.cancel()
        activeAnnotationQueryCancelToken = nil
        annotationQueryGeneration += 1
    }

    func scheduleAnnotationQueryRefresh() {
        annotationQueryWorkItem?.cancel()
        annotationQueryGeneration += 1
        let generation = annotationQueryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.annotationQueryGeneration == generation,
                          self.activeTab == .annotations else { return }
                    self.annotationQueryWorkItem = nil
                    self.updateDisplayedAnnotations()
                }
            }
        }
        annotationQueryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.annotationQueryDebounceInterval, execute: workItem)
    }

    /// Populates the variant table using viewport-region-filtered or global queries.
    ///
    /// When viewport sync is enabled and a viewport region is available, queries
    /// only the visible region. Otherwise falls back to global query or shows a
    /// placeholder message.
    /// Whether viewport sync is effectively active: enabled, connected to a viewer, and region available.
    var isViewportSyncActive: Bool {
        viewportSyncEnabled && (viewportSyncSourceIdentifier != nil || viewportSyncSourceObject != nil)
    }

    /// Whether the current query has user-entered filters/tokens.
    var hasActiveSearchFilters: Bool {
        if !activeSmartTokens.isEmpty { return true }
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !selectedVariantPresetByKey.isEmpty { return true }
        return false
    }

    /// Returns a narrowed sample set for variant queries when the user has hidden samples.
    /// Empty set means "no sample restriction".
    func selectedSamplesForVariantQuery() -> Set<String> {
        guard !allSampleNames.isEmpty else { return [] }
        let visible = Set(allSampleNames.filter { !currentSampleDisplayState.hiddenSamples.contains($0) })
        guard !visible.isEmpty, visible.count < allSampleNames.count else { return [] }
        return visible
    }

    func updateDisplayedVariants(
        index: AnnotationSearchIndex,
        typeFilter: Set<String>,
        query: VariantFilterQuery
    ) {
        let isLargeDatabase = totalVariantDatabaseSizeBytes() >= Self.chromosomeScopeThreshold
        let isMaterializedOnlyDatabase = isMaterializedOnlyModeEnabled()

        let chipInfoFilters: [VariantDatabase.InfoFilter] = isMaterializedOnlyDatabase ? [] : selectedVariantPresetByKey.map { key, value in
            VariantDatabase.InfoFilter(key: key, op: .eq, value: value)
        }

        // Compose smart token filters
        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let smartComposed = activeSmartTokens.composeFilters(infoKeys: infoKeySet)
        let filterBookmarkedOnly = smartComposed.postFilters.contains(where: {
            if case .bookmarkedOnly = $0 { return true }; return false
        })
        let filterModerateOrHigher = smartComposed.postFilters.contains(where: {
            if case .moderateOrHigherImpact = $0 { return true }; return false
        })
        // Extract within-sample AF range filter (for viral/bacterial smart tokens)
        let withinSampleAFRange: (min: Double, max: Double)? = smartComposed.postFilters.compactMap {
            if case .withinSampleAFRange(let lo, let hi) = $0 { return (min: lo, max: hi) }
            return nil
        }.first
        let hasSmartPostFilter = filterBookmarkedOnly || filterModerateOrHigher || withinSampleAFRange != nil

        // Merge type restrictions from smart tokens with existing type filter
        var effectiveTypeFilter = typeFilter
        if let explicitTypeFilter = query.explicitTypeFilter, !explicitTypeFilter.isEmpty {
            if effectiveTypeFilter.isEmpty {
                effectiveTypeFilter = explicitTypeFilter
            } else {
                effectiveTypeFilter = effectiveTypeFilter.intersection(explicitTypeFilter)
            }
        }
        if !smartComposed.typeRestrictions.isEmpty {
            if effectiveTypeFilter.isEmpty {
                effectiveTypeFilter = smartComposed.typeRestrictions
            } else {
                effectiveTypeFilter = effectiveTypeFilter.intersection(smartComposed.typeRestrictions)
            }
        }

        let mergedInfoFilters = query.infoFilters + chipInfoFilters + smartComposed.infoFilters
        let selectedSamples = selectedSamplesForVariantQuery()
        // Capture active SmartToken raw values for pre-materialized cache JOINs.
        let frozenActiveTokens = Set(activeSmartTokens.map(\.rawValue))

        // Build effective query with smart token overlays.
        // For very large databases, force materialized-token-only mode by dropping
        // user-authored query-builder clauses that are not backed by token caches.
        var effectiveQuery = query
        if isMaterializedOnlyDatabase {
            effectiveQuery = VariantFilterQuery()
        }
        effectiveQuery.infoFilters = mergedInfoFilters
        if let smartMinQ = smartComposed.minQuality, effectiveQuery.minQuality == nil {
            effectiveQuery.minQuality = smartMinQ
            effectiveQuery.minQualityInclusive = true
        }
        if let smartFilter = smartComposed.filterValue, effectiveQuery.filterValue == nil {
            effectiveQuery.filterValue = smartFilter
        }
        // Scope control is authoritative:
        // When the user has active text/token/preset filters and no explicit region clause,
        // queries run globally regardless of the scope control setting.  This ensures the
        // first filtered result set is genome-wide; viewport post-filtering narrows it
        // during exploration (see `allowViewportPostFilterDuringExploration`).
        let hasGlobalOverrideFilters = hasActiveSearchFilters
            && effectiveQuery.region == nil
        let viewportPostFilterRegion: (chromosome: String, start: Int, end: Int)? = {
            guard hasGlobalOverrideFilters,
                  viewportSyncEnabled,
                  allowViewportPostFilterDuringExploration,
                  let viewportRegion else { return nil }
            return viewportRegion
        }()
        let usePostFiltering = hasSmartPostFilter || effectiveQuery.hasPostFilters || viewportPostFilterRegion != nil

        // Freeze mutable vars as `let` for safe capture in the @Sendable dispatch closure.
        let frozenQuery = effectiveQuery
        let frozenTypeFilter = effectiveTypeFilter

        // Snapshot bookmark keys for background use (value copy).
        let bookmarkSnapshot = bookmarkedVariantKeys

        // Gene list query always runs globally, independent of viewport/annotation scope.
        let inferredGeneList = query.geneList == nil ? detectGeneListPattern(query.nameFilter) : nil
        let activeGeneList = query.geneList ?? inferredGeneList
        let cacheKey = VariantQueryCacheKey(
            filterText: variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines),
            tokens: activeSmartTokens.map(\.rawValue).sorted(),
            presets: selectedVariantPresetByKey.keys.sorted().map { "\($0)=\(selectedVariantPresetByKey[$0] ?? "")" },
            typeFilter: typeFilter.sorted(),
            explicitTypeFilter: (query.explicitTypeFilter ?? []).sorted(),
            infoFilters: mergedInfoFilters.map { "\($0.key)|\($0.op.rawValue)|\($0.value)" }.sorted(),
            filterValue: effectiveQuery.filterValue,
            minQuality: effectiveQuery.minQuality,
            minQualityInclusive: effectiveQuery.minQualityInclusive,
            maxQuality: effectiveQuery.maxQuality,
            maxQualityInclusive: effectiveQuery.maxQualityInclusive,
            minSampleCount: effectiveQuery.minSampleCount,
            minSampleCountInclusive: effectiveQuery.minSampleCountInclusive,
            maxSampleCount: effectiveQuery.maxSampleCount,
            maxSampleCountInclusive: effectiveQuery.maxSampleCountInclusive,
            nameFilter: effectiveQuery.nameFilter,
            geneList: activeGeneList ?? [],
            smartFilter: effectiveQuery.smartFilter?.predicates.map(\.description).sorted() ?? [],
            selectedSamples: selectedSamples.sorted()
        )

        // Determine the effective region for the query (fast — no database queries).
        let effectiveRegion: (chromosome: String, start: Int, end: Int)?
        var regionScope: VariantQueryScope = .global

        // For large databases (>1 GB), scope filtered queries to the current chromosome
        // instead of scanning genome-wide, which would be prohibitively slow.
        var filterChromosome: String?
        if activeGeneList != nil {
            // Gene list path — region is not used
            effectiveRegion = nil
            regionScope = .global
        } else if hasGlobalOverrideFilters {
            effectiveRegion = nil
            if isLargeDatabase, let vp = viewportRegion, viewportSyncEnabled {
                // Large database — scope to chromosome for performance
                filterChromosome = vp.chromosome
                regionScope = .chromosome
            } else {
                regionScope = viewportPostFilterRegion != nil ? .viewport : .global
            }
        } else if let selected = selectedAnnotationRegion {
            effectiveRegion = selected
            regionScope = .annotation
        } else if isViewportSyncActive {
            if let vp = viewportRegion {
                effectiveRegion = vp
                regionScope = .viewport
            } else {
                // Connected to a viewer but no region yet — show placeholder
                lastVariantQueryMatchCount = nil
                lastVariantQueryScope = .placeholder
                baseDisplayedVariantAnnotations = []
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                tooManyLabel.stringValue = "Navigate to a region to view variants"
                tooManyLabel.isHidden = false
                updateCountLabel()
                return
            }
        } else if viewportSyncEnabled, let annotationRegion = annotationSearchRegion {
            effectiveRegion = annotationRegion
            regionScope = .annotations
        } else {
            effectiveRegion = nil
        }

        // Freeze filterChromosome for safe capture in the @Sendable dispatch closure.
        let frozenFilterChromosome = filterChromosome

        // In Region scope, queries stay region-bound (viewport/annotation/query region).
        // In Genome scope, filtered queries can run globally.
        let requestedRegion = hasGlobalOverrideFilters ? nil : (frozenQuery.region ?? effectiveRegion)
        let frozenRegionScope = regionScope

        // No gene list active — dismiss tab bar immediately
        if activeGeneList == nil {
            delegate?.annotationDrawer(self, didResolveGeneRegions: [])
        }

        // Build the background query context from the index snapshot.
        var trackNameSnapshot: [String: String] = [:]
        for handle in index.variantDatabaseHandles {
            if let name = index.variantTrackName(for: handle.trackId) {
                trackNameSnapshot[handle.trackId] = name
            }
        }
        let ctx = AnnotationVariantQueryContext(
            databases: index.variantDatabaseHandles,
            trackNames: trackNameSnapshot,
            trackChromosomes: index.variantTrackChromosomeMap,
            annotationDatabases: index.annotationDatabaseHandles,
            infoKeys: infoKeySet,
            variantAliasMap: variantChromosomeAliasMap
        )
        let maxDisplay = Self.maxDisplayCount

        if hasGlobalOverrideFilters, let viewportPostFilterRegion,
           cachedGlobalFilteredVariantKey == cacheKey, !cachedGlobalFilteredVariantRows.isEmpty {
            let filtered = filterVariantsToRegionOffMain(
                cachedGlobalFilteredVariantRows,
                chromosome: viewportPostFilterRegion.chromosome,
                start: viewportPostFilterRegion.start,
                end: viewportPostFilterRegion.end
            )
            setVariantBaseResults(Array(filtered.prefix(maxDisplay)))
            lastVariantQueryMatchCount = displayedAnnotations.count
            lastVariantQueryScope = .viewport
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
            hideVariantQueryProgress()
            updateCountLabel()
            return
        }

        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()

        // Increment generation counter — any in-flight queries with older generations are stale.
        variantQueryGeneration += 1
        let thisGeneration = variantQueryGeneration
        let cancelToken = VariantQueryCancellationToken()
        activeVariantQueryCancelToken = cancelToken

        // Show progress indicator.
        showVariantQueryProgress("Searching variants\u{2026}")
        #if DEBUG
        debugVariantQueryExecutionCount += 1
        #endif

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.variantQueryWorkItem = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let shouldCancel = { cancelToken.isCancelled }
                if shouldCancel() { return }

                // Capture all query parameters as value types (already done above).
                let results: [AnnotationSearchIndex.SearchResult]
                let matchCount: Int?
                let queryScope: VariantQueryScope
                var tooManyMessage: String?
                var resolvedGeneRegions: [GeneRegion] = []
                var globalRowsForCache: [AnnotationSearchIndex.SearchResult]?

                // Build post-filter closure that operates only on captured value types.
                let applyAllPostFilters: ([AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] = { rows in
                    var filtered = applyVariantAdvancedFiltersOffMain(rows, query: frozenQuery)
                    if filterModerateOrHigher {
                        filtered = filterModerateOrHigherImpactOffMain(filtered)
                    }
                    if filterBookmarkedOnly {
                        filtered = filtered.filter { result in
                            guard let rowId = result.variantRowId else { return false }
                            let key = "\(result.trackId):\(rowId)"
                            return bookmarkSnapshot.contains(key)
                        }
                    }
                    if let afRange = withinSampleAFRange {
                        filtered = filterByWithinSampleAFOffMain(filtered, min: afRange.min, max: afRange.max)
                    }
                    return filtered
                }

                if let activeGeneList, !activeGeneList.isEmpty {
                    // Gene list path — query variants overlapping gene regions + INFO gene keys.
                    var geneQuery = frozenQuery
                    if inferredGeneList != nil {
                        geneQuery.nameFilter = ""
                    }
                    let needsGenePostFiltering = usePostFiltering || !geneQuery.nameFilter.isEmpty
                    let initialLimit = needsGenePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay
                    let geneQueryResult = ctx.queryVariantsForGenes(
                        activeGeneList,
                        types: frozenTypeFilter,
                        infoFilters: mergedInfoFilters,
                        sampleNames: selectedSamples,
                        smartFilter: frozenQuery.smartFilter,
                        activeTokens: frozenActiveTokens,
                        limit: max(initialLimit, maxDisplay),
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    resolvedGeneRegions = geneQueryResult.resolvedRegions
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: initialLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: needsGenePostFiltering,
                        fetch: { limit in
                            if limit <= geneQueryResult.results.count {
                                return Array(geneQueryResult.results.prefix(limit))
                            }
                            return ctx.queryVariantsForGenes(
                                activeGeneList,
                                types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                smartFilter: frozenQuery.smartFilter,
                                activeTokens: frozenActiveTokens,
                                limit: max(limit, maxDisplay),
                                shouldCancel: shouldCancel
                            ).results
                        },
                        postFilter: { rows in
                            var filteredRows = applyAllPostFilters(rows)
                            if !geneQuery.nameFilter.isEmpty {
                                let needle = geneQuery.nameFilter.lowercased()
                                filteredRows = filteredRows.filter { $0.name.lowercased().contains(needle) }
                            }
                            return filteredRows
                        },
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    globalRowsForCache = filtered
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                    } else {
                        results = filtered
                    }
                    matchCount = results.count
                    queryScope = viewportPostFilterRegion != nil ? .viewport : .global
                    tooManyMessage = nil

                } else if let region = requestedRegion {
                    // Region-scoped query — probe fetch pattern (no separate COUNT).
                    let probeLimit = usePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay + 1
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: probeLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: usePostFiltering,
                        fetch: { limit in
                            ctx.queryVariantsInRegion(
                                chromosome: region.chromosome, start: region.start, end: region.end,
                                nameFilter: frozenQuery.nameFilter, types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                smartFilter: frozenQuery.smartFilter,
                                activeTokens: frozenActiveTokens,
                                limit: limit,
                                shouldCancel: shouldCancel
                            )
                        },
                        postFilter: applyAllPostFilters,
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                        matchCount = results.count
                    } else if filtered.count > maxDisplay {
                        // Probe returned more than maxDisplay — show first maxDisplay with "N+" count
                        results = Array(filtered.prefix(maxDisplay))
                        matchCount = nil  // signals "more than displayed" for N+ label
                    } else {
                        results = filtered
                        matchCount = filtered.count
                    }
                    queryScope = frozenRegionScope
                    tooManyMessage = nil

                } else {
                    // Global query — probe fetch pattern (no separate COUNT).
                    let probeLimit = usePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay + 1
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: probeLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: usePostFiltering,
                        fetch: { limit in
                            ctx.queryVariantsOnly(
                                chromosome: frozenFilterChromosome,
                                nameFilter: frozenQuery.nameFilter, types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                smartFilter: frozenQuery.smartFilter,
                                activeTokens: frozenActiveTokens,
                                limit: limit,
                                shouldCancel: shouldCancel
                            )
                        },
                        postFilter: applyAllPostFilters,
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    globalRowsForCache = filtered
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                        matchCount = results.count
                    } else if filtered.count > maxDisplay {
                        // Probe returned more than maxDisplay — show first maxDisplay with "N+" count
                        results = Array(filtered.prefix(maxDisplay))
                        matchCount = nil  // signals "more than displayed" for N+ label
                    } else {
                        results = filtered
                        matchCount = filtered.count
                    }
                    if frozenFilterChromosome != nil {
                        queryScope = .chromosome
                    } else {
                        queryScope = viewportPostFilterRegion != nil ? .viewport : .global
                    }
                    tooManyMessage = nil
                }

                // Deliver results on main thread.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.variantQueryGeneration == thisGeneration,
                              self.activeTab == .variants else { return }
                        self.hideVariantQueryProgress()
                        self.setVariantBaseResults(results)
                        self.lastVariantQueryMatchCount = matchCount
                        self.lastVariantQueryScope = queryScope
                        self.activeVariantQueryCancelToken = nil
                        if hasGlobalOverrideFilters, let rows = globalRowsForCache {
                            self.cachedGlobalFilteredVariantRows = rows
                            self.cachedGlobalFilteredVariantKey = cacheKey
                        } else if !hasGlobalOverrideFilters {
                            self.cachedGlobalFilteredVariantRows = []
                            self.cachedGlobalFilteredVariantKey = nil
                        }

                        if let tooManyMessage {
                            self.tableView.reloadData()
                            self.scrollView.isHidden = true
                            self.tooManyLabel.stringValue = tooManyMessage
                            self.tooManyLabel.isHidden = false
                        } else {
                            self.tableView.reloadData()
                            self.scrollView.isHidden = false
                            self.tooManyLabel.isHidden = true
                        }

                        if activeGeneList != nil {
                            self.delegate?.annotationDrawer(self, didResolveGeneRegions: resolvedGeneRegions)
                        }

                        self.updateCountLabel()

                        // Rebuild genotypes if the genotype subtab is active.
                        if self.activeVariantSubtab == .genotypes {
                            self.buildGenotypeRows()
                        }
                    }
                }
            }
        }
        variantQueryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.variantQueryDebounceInterval, execute: workItem)
    }

    func filterByWithinSampleAF(
        _ results: [AnnotationSearchIndex.SearchResult],
        min: Double,
        max: Double
    ) -> [AnnotationSearchIndex.SearchResult] {
        // Use only the plain "AF" key for within-sample frequency (not population keys
        // like gnomAD_AF). For haploid organisms, INFO AF is within-sample frequency.
        return results.filter { result in
            guard let info = result.infoDict,
                  let raw = info["AF"] ?? info["af"],
                  !raw.isEmpty else { return false }
            // Handle multi-allelic: "0.05,0.12" — use the max AF across alts
            let values = raw.split(separator: ",").compactMap { Double($0) }
            guard let af = values.max() else { return false }
            return af >= min && af <= max
        }
    }

    func filterModerateOrHigherImpact(_ results: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        let impactKeys = SmartToken.impactKeys
        return results.filter { result in
            guard let info = result.infoDict else { return false }
            for key in impactKeys {
                guard let raw = info[key], !raw.isEmpty else { continue }
                let value = raw.uppercased()
                if value.contains("HIGH") || value.contains("MODERATE") {
                    return true
                }
            }
            return false
        }
    }

    func updateCountLabel() {
        defer {
            emitVisibleVariantRenderKeyUpdateIfNeeded()
            emitVisibleAnnotationRenderKeyUpdateIfNeeded()
        }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            let count = displayedGenotypes.count
            countLabel.stringValue = "\(count) genotype\(count == 1 ? "" : "s")"
            return
        }
        if activeTab == .samples {
            let total = allSampleRowKeys.count
            let shown = displayedSamples.count
            let hidden = allSampleRowKeys.reduce(into: 0) { count, rowKey in
                guard let sampleName = sampleNameByRowKey[rowKey] else { return }
                if currentSampleDisplayState.hiddenSamples.contains(sampleName) {
                    count += 1
                }
            }
            if isLoading {
                countLabel.stringValue = "Loading..."
            } else if shown == total {
                let hiddenStr = hidden > 0 ? " (\(hidden) hidden)" : ""
                countLabel.stringValue = "\(total) samples\(hiddenStr)"
            } else {
                countLabel.stringValue = "\(shown) of \(total) samples"
            }
            return
        }

        let entityName = activeTab == .annotations ? "annotations" : "variants"
        let activeTotal = activeTab == .annotations ? totalAnnotationCount : totalVariantCount

        if isLoading {
            countLabel.stringValue = "Building annotation index (scanning all chromosomes)..."
        } else if activeTab == .annotations && !annotationColumnFilterClauses.isEmpty {
            let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
            let base = numberFormatter.string(from: NSNumber(value: baseDisplayedAnnotationRows.count)) ?? "\(baseDisplayedAnnotationRows.count)"
            let filterDesc = annotationColumnFilterClauses.map { clause in
                let displayKey = clause.key.hasPrefix("attr_") ? String(clause.key.dropFirst(5)) : clause.key
                if clause.value.isEmpty {
                    return clause.op == "=" ? "\(displayKey) is empty" : "\(displayKey) is not empty"
                }
                return "\(displayKey)\(clause.op)\(clause.value)"
            }.joined(separator: ", ")
            countLabel.stringValue = "\(shown) of \(base) shown (\(filterDesc))"
        } else if activeTab == .variants {
            // Unified variant count label using tracked scope and match count.
            // matchCount == nil signals "more than displayed" (probe fetch overflow) → show "N+" format.
            if !variantColumnFilterClauses.isEmpty {
                let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
                let base = numberFormatter.string(from: NSNumber(value: baseDisplayedVariantAnnotations.count)) ?? "\(baseDisplayedVariantAnnotations.count)"
                let filterDesc = variantColumnFilterClauses.map { clause in
                    let displayKey = clause.key.hasPrefix("info_") ? String(clause.key.dropFirst(5)) : clause.key
                    if clause.value.isEmpty {
                        return clause.op == "=" ? "\(displayKey) is empty" : "\(displayKey) is not empty"
                    }
                    return "\(displayKey)\(clause.op)\(clause.value)"
                }.joined(separator: ", ")
                countLabel.stringValue = "\(shown) of \(base) shown (\(filterDesc))"
                return
            }
            let total = numberFormatter.string(from: NSNumber(value: totalVariantCount)) ?? "\(totalVariantCount)"
            let displayCount = displayedAnnotations.count
            let displayCountStr = numberFormatter.string(from: NSNumber(value: displayCount)) ?? "\(displayCount)"
            switch lastVariantQueryScope {
            case .placeholder:
                countLabel.stringValue = "\(total) variants total"
            case .annotation:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) overlapping (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ overlapping (\(total) total)"
                }
            case .chromosome:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) on chromosome (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ on chromosome (\(total) total)"
                }
            case .viewport:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) in viewport (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ in viewport (\(total) total)"
                }
            case .annotations:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) near annotations (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ near annotations (\(total) total)"
                }
            case .global:
                if !tooManyLabel.isHidden {
                    countLabel.stringValue = "\(total) total — filter to browse"
                } else if let count = lastVariantQueryMatchCount, count == totalVariantCount {
                    countLabel.stringValue = "\(total) variants"
                } else if lastVariantQueryMatchCount == nil {
                    countLabel.stringValue = "\(displayCountStr)+ of \(total)"
                } else {
                    let shown = numberFormatter.string(from: NSNumber(value: displayCount)) ?? "\(displayCount)"
                    countLabel.stringValue = "\(shown) of \(total)"
                }
            }
        } else if !tooManyLabel.isHidden {
            let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
            countLabel.stringValue = "\(total) total — filter to browse"
        } else if displayedAnnotations.count == activeTotal {
            countLabel.stringValue = "\(numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)") \(entityName)"
        } else {
            let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
            let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
            countLabel.stringValue = "\(shown) of \(total)"
        }
    }

    func updateLoadingState() {
        loadingIndicator.isHidden = !isLoading
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        updateCountLabel()
    }

    @objc func filterFieldChanged(_ sender: NSSearchField) {
        switch activeTab {
        case .annotations:
            annotationFilterText = sender.stringValue
            if annotationFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateDisplayedAnnotations()
            } else {
                scheduleAnnotationQueryRefresh()
            }
            return
        case .variants:
            variantFilterText = sender.stringValue
            markVariantFilterStateMutated()
        case .samples:
            sampleFilterText = sender.stringValue
        }
        // Clear annotation-specific region when user types on variants tab
        if activeTab == .variants {
            selectedAnnotationRegion = nil
        }
        if activeTab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }
    }

    @objc func annotationViewportFilterToggled(_ sender: NSButton) {
        setAnnotationViewportFilterEnabled(sender.state == .on)
    }

    func setAnnotationViewportFilterEnabled(_ enabled: Bool) {
        guard annotationViewportFilterEnabled != enabled else { return }
        annotationViewportFilterEnabled = enabled
        annotationViewportFilterButton.state = enabled ? .on : .off
        emitVisibleAnnotationRenderKeyUpdateIfNeeded()
    }

    var isAnnotationViewportFilterControlVisible: Bool {
        !annotationViewportFilterButton.isHidden
    }

    var annotationTrackDisplayState: AnnotationTrackDisplayState {
        AnnotationTrackDisplayState(
            order: annotationTrackOrder,
            hiddenTrackIDs: hiddenAnnotationTrackIDs,
            displayNames: annotationTrackDisplayNames
        )
    }

    func syncAnnotationTracks(from trackIDs: [String]) {
        let previousState = annotationTrackDisplayState
        var seen: Set<String> = []
        let discovered = trackIDs.filter { trackID in
            guard !trackID.isEmpty, !seen.contains(trackID) else { return false }
            seen.insert(trackID)
            return true
        }
        guard !discovered.isEmpty else {
            let changed = !annotationTrackOrder.isEmpty
                || !hiddenAnnotationTrackIDs.isEmpty
                || !annotationTrackDisplayNames.isEmpty
            annotationTrackOrder = []
            hiddenAnnotationTrackIDs = []
            annotationTrackDisplayNames = [:]
            updateSearchFieldVisibility()
            if changed {
                emitAnnotationTrackDisplayStateIfNeeded()
            }
            return
        }

        let discoveredSet = Set(discovered)
        var nextOrder = annotationTrackOrder.filter { discoveredSet.contains($0) }
        let orderedSet = Set(nextOrder)
        nextOrder.append(contentsOf: discovered.filter { !orderedSet.contains($0) })

        annotationTrackOrder = nextOrder
        hiddenAnnotationTrackIDs = hiddenAnnotationTrackIDs.intersection(discoveredSet)
        annotationTrackDisplayNames = annotationTrackDisplayNames.filter { discoveredSet.contains($0.key) }
        for trackID in discovered where annotationTrackDisplayNames[trackID] == nil {
            annotationTrackDisplayNames[trackID] = trackID
        }
        let changed = annotationTrackDisplayState != previousState

        updateSearchFieldVisibility()
        if changed {
            emitAnnotationTrackDisplayStateIfNeeded()
        }
    }

    func emitAnnotationTrackDisplayStateIfNeeded() {
        let state = annotationTrackDisplayState
        guard state != lastEmittedAnnotationTrackDisplayState else { return }
        lastEmittedAnnotationTrackDisplayState = state
        delegate?.annotationDrawer(self, didUpdateAnnotationTrackDisplayState: state)
    }

    func setAnnotationTrackVisible(trackId: String, visible: Bool) {
        guard annotationTrackOrder.contains(trackId) else { return }
        if visible {
            hiddenAnnotationTrackIDs.remove(trackId)
        } else {
            hiddenAnnotationTrackIDs.insert(trackId)
        }
        emitAnnotationTrackDisplayStateIfNeeded()
    }

    func moveAnnotationTrack(trackId: String, direction: AnnotationTrackMoveDirection) {
        guard let index = annotationTrackOrder.firstIndex(of: trackId) else { return }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = max(0, index - 1)
        case .down:
            targetIndex = min(annotationTrackOrder.count - 1, index + 1)
        }
        guard targetIndex != index else { return }
        annotationTrackOrder.swapAt(index, targetIndex)
        emitAnnotationTrackDisplayStateIfNeeded()
    }

    @objc func showAnnotationTracksMenu(_ sender: NSButton) {
        let menu = NSMenu()
        if annotationTrackOrder.isEmpty {
            let item = NSMenuItem(title: "No Annotation Tracks", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for trackID in annotationTrackOrder {
                let item = NSMenuItem(title: annotationTrackDisplayNames[trackID] ?? trackID, action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                let visibleItem = NSMenuItem(
                    title: "Visible",
                    action: #selector(toggleAnnotationTrackVisibility(_:)),
                    keyEquivalent: ""
                )
                visibleItem.target = self
                visibleItem.representedObject = trackID
                visibleItem.state = hiddenAnnotationTrackIDs.contains(trackID) ? .off : .on
                submenu.addItem(visibleItem)

                submenu.addItem(.separator())

                let moveUpItem = NSMenuItem(
                    title: "Move Up",
                    action: #selector(moveAnnotationTrackUp(_:)),
                    keyEquivalent: ""
                )
                moveUpItem.target = self
                moveUpItem.representedObject = trackID
                moveUpItem.isEnabled = annotationTrackOrder.first != trackID
                submenu.addItem(moveUpItem)

                let moveDownItem = NSMenuItem(
                    title: "Move Down",
                    action: #selector(moveAnnotationTrackDown(_:)),
                    keyEquivalent: ""
                )
                moveDownItem.target = self
                moveDownItem.representedObject = trackID
                moveDownItem.isEnabled = annotationTrackOrder.last != trackID
                submenu.addItem(moveDownItem)

                submenu.addItem(.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete Track\u{2026}",
                    action: #selector(deleteAnnotationTrackFromMenu(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = trackID
                deleteItem.isEnabled = allowsAnnotationEditing
                submenu.addItem(deleteItem)

                item.submenu = submenu
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc func toggleAnnotationTrackVisibility(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        setAnnotationTrackVisible(trackId: trackID, visible: hiddenAnnotationTrackIDs.contains(trackID))
    }

    @objc func moveAnnotationTrackUp(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        moveAnnotationTrack(trackId: trackID, direction: .up)
    }

    @objc func moveAnnotationTrackDown(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        moveAnnotationTrack(trackId: trackID, direction: .down)
    }

    @objc func deleteAnnotationTrackFromMenu(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        delegate?.annotationDrawer(
            self,
            didRequestDeleteAnnotationTrack: trackID,
            trackName: annotationTrackDisplayNames[trackID] ?? trackID
        )
    }

    struct AnnotationFilterQuery: Sendable {
        var nameFilter: String = ""
        var typeFilter: Set<String>?
        var chromosome: String?
        var strand: String?
        var start: Int?
        var end: Int?
    }

    struct VariantFilterQuery {
        var nameFilter: String = ""
        var explicitTypeFilter: Set<String>?
        var infoFilters: [VariantDatabase.InfoFilter] = []
        var region: (chromosome: String, start: Int, end: Int)?
        var minQuality: Double?
        var minQualityInclusive: Bool = true
        var maxQuality: Double?
        var maxQualityInclusive: Bool = true
        var minSampleCount: Int?
        var minSampleCountInclusive: Bool = true
        var maxSampleCount: Int?
        var maxSampleCountInclusive: Bool = true
        /// If set, only show variants where FILTER column matches (e.g. "PASS").
        var filterValue: String?
        /// If set, restrict results to variants overlapping these gene names.
        var geneList: [String]?
        /// Per-sample genotype/depth/frequency predicates that must be executed in SQL.
        var smartFilter: VariantSmartFilter?

        var hasPostFilters: Bool {
            minQuality != nil || maxQuality != nil || minSampleCount != nil || maxSampleCount != nil || filterValue != nil
        }
    }

    struct SampleFilterQuery {
        var textFilter: String = ""
        var nameFilter: (op: String, value: String)?
        var sourceFilter: (op: String, value: String)?
        var visibility: Bool?
        var metadataFilters: [(field: String, op: String, value: String)] = []
    }

    struct ColumnFilterClause: Sendable {
        var key: String
        var op: String
        var value: String
    }
    typealias VariantColumnFilterClause = ColumnFilterClause

    struct ParsedSearchClause {
        var key: String?
        var op: String
        var value: String
    }

    /// Semicolon-delimited parser used for explicit advanced search, e.g.:
    /// `chr=NC_041760.1;pos=100-200;qual>=30;DP>=20`.
    func parseSearchClauses(_ text: String) -> [ParsedSearchClause] {
        let operators = ["!~", "^=", "$=", ">=", "<=", "!=", "~", ">", "<", "="]
        return text.split(separator: ";").compactMap { segment in
            let token = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            for op in operators {
                if let range = token.range(of: op) {
                    let key = String(token[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(token[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty {
                        return ParsedSearchClause(key: nil, op: op, value: String(value))
                    }
                    return ParsedSearchClause(key: String(key), op: op, value: String(value))
                }
            }
            return ParsedSearchClause(key: nil, op: "", value: token)
        }
    }

    func infoComparisonOp(from op: String) -> VariantDatabase.InfoFilter.ComparisonOp {
        switch op {
        case ">": return .gt
        case ">=": return .gte
        case "<": return .lt
        case "<=": return .lte
        case "!=": return .neq
        case "~": return .like
        default: return .eq
        }
    }

    func parseVariantTypesList(_ raw: String) -> Set<String> {
        Set(
            raw.split(whereSeparator: { $0 == "," || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Parses advanced annotation search syntax:
    /// `type:gene chr:NC_045512 strand:+ region:NC_045512:100-900 myName`
    func parseAnnotationFilterText(_ text: String) -> AnnotationFilterQuery {
        if text.contains(";") {
            var query = AnnotationFilterQuery()
            var freeTokens: [String] = []
            for clause in parseSearchClauses(text) {
                guard let rawKey = clause.key?.lowercased() else {
                    freeTokens.append(clause.value)
                    continue
                }
                switch rawKey {
                case "text", "name", "id":
                    freeTokens.append(clause.value)
                case "type":
                    let values = clause.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !values.isEmpty {
                        query.typeFilter = Set(values)
                    }
                case "chr", "chrom", "chromosome":
                    query.chromosome = clause.value
                case "strand":
                    query.strand = clause.value
                case "start":
                    query.start = Int(clause.value)
                case "end":
                    query.end = Int(clause.value)
                case "region":
                    if let parsed = parseRegion(clause.value) {
                        query.chromosome = parsed.chromosome
                        query.start = parsed.start
                        query.end = parsed.end
                    }
                default:
                    freeTokens.append(clause.value)
                }
            }
            query.nameFilter = freeTokens.joined(separator: " ")
            return query
        }

        var query = AnnotationFilterQuery()
        var freeTokens: [String] = []
        for tokenSub in text.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let value = token.value(after: "type:") {
                query.typeFilter = [value]
            } else if let value = token.value(after: "chr:") ?? token.value(after: "chrom:") {
                query.chromosome = value
            } else if let value = token.value(after: "strand:") {
                query.strand = value
            } else if let value = token.value(after: "start:"), let parsed = Int(value) {
                query.start = parsed
            } else if let value = token.value(after: "end:"), let parsed = Int(value) {
                query.end = parsed
            } else if let value = token.value(after: "region:"), let parsed = parseRegion(value) {
                query.chromosome = parsed.chromosome
                query.start = parsed.start
                query.end = parsed.end
            } else {
                freeTokens.append(token)
            }
        }
        query.nameFilter = freeTokens.joined(separator: " ")
        return query
    }

    /// Parses advanced variant syntax:
    /// `chr:7 pos:100-200 DP>20 AF>=0.01 qual>=30 sc>=2 rs123`
    func parseVariantFilterText(_ text: String) -> VariantFilterQuery {
        if text.contains(";") {
            var query = VariantFilterQuery()
            var nameTokens: [String] = []
            var smartClauses: [String] = []
            for clause in parseSearchClauses(text) {
                let rawClause = {
                    if let key = clause.key {
                        return "\(key)\(clause.op)\(clause.value)"
                    }
                    return clause.value
                }()
                if (try? VariantSmartFilter.parse(rawClause)) != nil {
                    smartClauses.append(rawClause)
                    continue
                }
                guard let rawKeyText = clause.key?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKeyText.isEmpty else {
                    if let parsed = VariantDatabase.InfoFilter.parse(clause.value) {
                        query.infoFilters.append(resolveVariantInfoFilter(parsed))
                    } else {
                        nameTokens.append(clause.value)
                    }
                    continue
                }
                let rawKey = rawKeyText.lowercased()
                switch rawKey {
                case "text", "name", "id":
                    nameTokens.append(clause.value)
                case "chr", "chrom", "chromosome":
                    let value = clause.value
                    if let region = query.region {
                        query.region = (value, region.start, region.end)
                    } else {
                        query.region = (value, 0, Int.max)
                    }
                case "pos", "range":
                    if let range = parseRange(clause.value) {
                        let chr = query.region?.chromosome ?? viewportRegion?.chromosome ?? ""
                        if !chr.isEmpty {
                            query.region = (chr, range.start, range.end)
                        }
                    }
                case "region":
                    if let parsed = parseRegion(clause.value) {
                        query.region = parsed
                    }
                case "qual", "quality":
                    if let value = Double(clause.value) {
                        switch clause.op {
                        case ">", ">=":
                            query.minQuality = value
                            query.minQualityInclusive = clause.op == ">="
                        case "<", "<=":
                            query.maxQuality = value
                            query.maxQualityInclusive = clause.op == "<="
                        default:
                            query.minQuality = value
                            query.maxQuality = value
                            query.minQualityInclusive = true
                            query.maxQualityInclusive = true
                        }
                    }
                case "sc", "samples", "samplecount":
                    if let value = Double(clause.value) {
                        let count = Int(value.rounded())
                        switch clause.op {
                        case ">", ">=":
                            query.minSampleCount = count
                            query.minSampleCountInclusive = clause.op == ">="
                        case "<", "<=":
                            query.maxSampleCount = count
                            query.maxSampleCountInclusive = clause.op == "<="
                        default:
                            query.minSampleCount = count
                            query.maxSampleCount = count
                            query.minSampleCountInclusive = true
                            query.maxSampleCountInclusive = true
                        }
                    }
                case "filter":
                    query.filterValue = clause.value
                case "genes", "genelist", "gene_list":
                    let genes = clause.value
                        .replacingOccurrences(of: "\n", with: ",")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !genes.isEmpty {
                        query.geneList = (query.geneList ?? []) + genes
                    }
                case "type", "variant_type":
                    let parsedTypes = parseVariantTypesList(clause.value)
                    if !parsedTypes.isEmpty {
                        if let existing = query.explicitTypeFilter {
                            query.explicitTypeFilter = existing.intersection(parsedTypes)
                        } else {
                            query.explicitTypeFilter = parsedTypes
                        }
                    }
                default:
                    guard !clause.value.isEmpty else { continue }
                    query.infoFilters.append(
                        VariantDatabase.InfoFilter(
                            key: resolveVariantInfoKey(rawKeyText),
                            op: infoComparisonOp(from: clause.op),
                            value: clause.value
                        )
                    )
                }
            }
            query.nameFilter = nameTokens.joined(separator: " ")
            if !smartClauses.isEmpty {
                query.smartFilter = try? VariantSmartFilter.parse(smartClauses.joined(separator: "; "))
            }
            if let region = query.region, region.chromosome.isEmpty {
                query.region = nil
            }
            return query
        }

        var query = VariantFilterQuery()
        var nameTokens: [String] = []

        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let knownClausePrefixes = [
            "chr:", "chrom:", "pos:", "range:",
            "type:", "type=", "variant_type:", "variant_type=",
            "genes=", "genes:", "genelist=", "genelist:", "gene_list=", "gene_list:",
            "filter=", "filter:"
        ]

        var idx = 0
        while idx < tokens.count {
            let token = tokens[idx]
            if let value = token.value(after: "chr:") ?? token.value(after: "chrom:") {
                if let region = query.region {
                    query.region = (value, region.start, region.end)
                } else {
                    query.region = (value, 0, Int.max)
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "pos:") ?? token.value(after: "range:"),
               let range = parseRange(value) {
                let chr = query.region?.chromosome ?? viewportRegion?.chromosome ?? ""
                if !chr.isEmpty {
                    query.region = (chr, range.start, range.end)
                }
                idx += 1
                continue
            }
            if let opValue = parseComparisonToken(token, keys: ["qual", "quality"]) {
                if opValue.op == ">" || opValue.op == ">=" {
                    query.minQuality = opValue.value
                    query.minQualityInclusive = opValue.op == ">="
                } else if opValue.op == "<" || opValue.op == "<=" {
                    query.maxQuality = opValue.value
                    query.maxQualityInclusive = opValue.op == "<="
                }
                idx += 1
                continue
            }
            if let opValue = parseComparisonToken(token, keys: ["sc", "samples", "samplecount"]) {
                let count = Int(opValue.value.rounded())
                if opValue.op == ">" || opValue.op == ">=" {
                    query.minSampleCount = count
                    query.minSampleCountInclusive = opValue.op == ">="
                } else if opValue.op == "<" || opValue.op == "<=" {
                    query.maxSampleCount = count
                    query.maxSampleCountInclusive = opValue.op == "<="
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "type:") ?? token.value(after: "type=") ?? token.value(after: "variant_type:") {
                let parsedTypes = parseVariantTypesList(value)
                if !parsedTypes.isEmpty {
                    if let existing = query.explicitTypeFilter {
                        query.explicitTypeFilter = existing.intersection(parsedTypes)
                    } else {
                        query.explicitTypeFilter = parsedTypes
                    }
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "genes=") ?? token.value(after: "genelist=") ?? token.value(after: "gene_list=")
                            ?? token.value(after: "genes:") ?? token.value(after: "genelist:") ?? token.value(after: "gene_list:") {
                var geneValue = value
                while geneValue.hasSuffix(",") && idx + 1 < tokens.count {
                    let next = tokens[idx + 1]
                    let nextLower = next.lowercased()
                    let nextStartsClause = knownClausePrefixes.contains { nextLower.hasPrefix($0) }
                        || VariantDatabase.InfoFilter.parse(next) != nil
                        || parseComparisonToken(next, keys: ["qual", "quality", "sc", "samples", "samplecount"]) != nil
                    if nextStartsClause {
                        break
                    }
                    geneValue += next
                    idx += 1
                }

                let genes = geneValue
                    .replacingOccurrences(of: "\n", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !genes.isEmpty {
                    query.geneList = (query.geneList ?? []) + genes
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "filter=") ?? token.value(after: "filter:") {
                query.filterValue = value
                idx += 1
                continue
            }
            if let parsed = VariantDatabase.InfoFilter.parse(token) {
                if (try? VariantSmartFilter.parse(token)) != nil {
                    query.smartFilter = try? VariantSmartFilter.parse(
                        ([query.smartFilter?.predicates.map(\.description).joined(separator: "; "), token]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty })
                            .joined(separator: "; ")
                    )
                } else {
                    query.infoFilters.append(resolveVariantInfoFilter(parsed))
                }
                idx += 1
                continue
            }
            nameTokens.append(token)
            idx += 1
        }
        query.nameFilter = nameTokens.joined(separator: " ")
        // Discard placeholder region if no valid chromosome was specified.
        if let region = query.region, region.chromosome.isEmpty {
            query.region = nil
        }
        return query
    }

    /// Resolves a user-facing or logical INFO key (e.g. "IMPACT", "GENE") to a concrete
    /// INFO key present in the loaded VCF, preferring exact/real keys when available.
    func resolveVariantInfoKey(_ requestedKey: String) -> String {
        let trimmed = requestedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return requestedKey }

        let availableKeys = infoColumnKeys.map(\.key)
        let availableSet = Set(availableKeys)
        if availableSet.contains(trimmed) {
            return trimmed
        }
        if let caseInsensitiveMatch = availableKeys.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return caseInsensitiveMatch
        }

        let normalized = trimmed.lowercased()
        let aliases: [String]
        switch normalized {
        case "impact":
            aliases = ["CSQ_IMPACT", "ANN_IMPACT", "IMPACT", "impact"]
        case "gene":
            aliases = ["CSQ_SYMBOL", "ANN_Gene", "GENE", "Gene", "gene", "GENEINFO"]
        case "clnsig", "clinvar", "clinvar_sig":
            aliases = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
        case "af":
            aliases = ["AF", "af", "gnomAD_AF", "gnomADe_AF", "gnomADg_AF", "ExAC_AF", "1000G_AF", "MAX_AF"]
        default:
            aliases = []
        }

        for alias in aliases where availableSet.contains(alias) {
            return alias
        }
        return trimmed
    }

    func resolveVariantInfoFilter(_ filter: VariantDatabase.InfoFilter) -> VariantDatabase.InfoFilter {
        VariantDatabase.InfoFilter(
            key: resolveVariantInfoKey(filter.key),
            op: filter.op,
            value: filter.value
        )
    }

    #if DEBUG
    func debugParseVariantFilterText(_ text: String) -> (nameFilter: String, geneList: [String], filterValue: String?) {
        let query = parseVariantFilterText(text)
        return (query.nameFilter, query.geneList ?? [], query.filterValue)
    }

    func debugParseVariantInfoFilterKeys(_ text: String) -> [String] {
        parseVariantFilterText(text).infoFilters.map(\.key)
    }

    func debugParseVariantSmartFilterDescriptions(_ text: String) -> [String] {
        parseVariantFilterText(text).smartFilter?.predicates.map(\.description) ?? []
    }

    func debugSetVariantScopeRegionEnabled(_ enabled: Bool) {
        viewportSyncEnabled = enabled
        updateScopeControlSelection()
    }

    func debugSetViewportRegion(chromosome: String, start: Int, end: Int) {
        viewportRegion = (chromosome: chromosome, start: start, end: end)
    }

    func debugSetVariantFilterText(_ text: String) {
        variantFilterText = text
        updateVariantFilterIndicator()
    }

    func debugSetAnnotationFilterText(_ text: String) {
        annotationFilterText = text
        annotationFilterField.stringValue = text
    }

    var debugAnnotationTrackDisplayState: AnnotationTrackDisplayState {
        annotationTrackDisplayState
    }

    func debugSetAnnotationTrackVisible(trackId: String, visible: Bool) {
        setAnnotationTrackVisible(trackId: trackId, visible: visible)
    }

    func debugMoveAnnotationTrack(trackId: String, direction: AnnotationTrackMoveDirection) {
        moveAnnotationTrack(trackId: trackId, direction: direction)
    }

    func debugSetSelectedAnnotationRegion(chromosome: String, start: Int, end: Int) {
        selectedAnnotationRegion = (chromosome: chromosome, start: start, end: end)
    }

    func debugRefreshDisplayedAnnotations() {
        updateDisplayedAnnotations()
    }

    func debugMarkViewportExploration() {
        allowViewportPostFilterDuringExploration = true
    }

    func debugGetAnnotationQueryExecutionCount() -> Int {
        debugAnnotationQueryExecutionCount
    }

    func debugGetVariantQueryExecutionCount() -> Int {
        debugVariantQueryExecutionCount
    }

    var debugSelectedAnnotationNames: [String] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < displayedAnnotations.count else { return nil }
            return displayedAnnotations[index].name
        }
    }

    var debugSelectedAnnotationStarts: [Int] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < displayedAnnotations.count else { return nil }
            return displayedAnnotations[index].start
        }
    }
    #endif

    /// Parses advanced sample syntax:
    /// `name:S1 source:run42 visible:true meta.Country:USA`
    func parseSampleFilterText(_ text: String) -> SampleFilterQuery {
        let normalizedInput = text.replacingOccurrences(
            of: #"^\s*samples:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let explicitClauseOperators = ["!~", "^=", "$=", "!=", "~", "="]
        let hasExplicitClauseSyntax = explicitClauseOperators.contains { normalizedInput.contains($0) }
        if normalizedInput.contains(";") || hasExplicitClauseSyntax {
            var query = SampleFilterQuery()
            var freeTokens: [String] = []
            for clause in parseSearchClauses(normalizedInput) {
                guard let rawKey = clause.key?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty else {
                    freeTokens.append(clause.value)
                    continue
                }
                let key = rawKey.lowercased()
                switch key {
                case "text":
                    freeTokens.append(clause.value)
                case "name":
                    query.nameFilter = (op: clause.op, value: clause.value)
                case "source":
                    query.sourceFilter = (op: clause.op, value: clause.value)
                case "visible":
                    let lower = clause.value.lowercased()
                    if ["1", "true", "yes", "on"].contains(lower) {
                        query.visibility = clause.op == "!=" ? false : true
                    }
                    if ["0", "false", "no", "off"].contains(lower) {
                        query.visibility = clause.op == "!=" ? true : false
                    }
                default:
                    if key.hasPrefix("meta.") {
                        let field = String(rawKey.dropFirst(5))
                        if !field.isEmpty {
                            query.metadataFilters.append((field: field, op: clause.op, value: clause.value))
                        }
                    } else {
                        // Treat unknown keys as metadata fields for convenience.
                        query.metadataFilters.append((field: rawKey, op: clause.op, value: clause.value))
                    }
                }
            }
            query.textFilter = freeTokens.joined(separator: " ")
            return query
        }

        var query = SampleFilterQuery()
        var freeTokens: [String] = []
        for tokenSub in normalizedInput.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let value = token.value(after: "name:") {
                query.nameFilter = (op: "~", value: value)
            } else if let value = token.value(after: "source:") {
                query.sourceFilter = (op: "~", value: value)
            } else if let value = token.value(after: "visible:") {
                let lower = value.lowercased()
                if ["1", "true", "yes", "on"].contains(lower) { query.visibility = true }
                if ["0", "false", "no", "off"].contains(lower) { query.visibility = false }
            } else if token.lowercased().hasPrefix("meta."),
                      let sep = token.firstIndex(of: ":") {
                let key = String(token[token.index(token.startIndex, offsetBy: 5)..<sep])
                let value = String(token[token.index(after: sep)...])
                if !key.isEmpty, !value.isEmpty {
                    query.metadataFilters.append((field: key, op: "~", value: value))
                }
            } else {
                freeTokens.append(token)
            }
        }
        query.textFilter = freeTokens.joined(separator: " ")
        return query
    }

    var hasActiveSampleFilters: Bool {
        if !sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !activeSampleTokens.isEmpty { return true }
        if selectedSampleGroupId != nil { return true }
        return false
    }

    func updateSampleFilterIndicator() {
        let isSamplesTab = activeTab == .samples
        clearSampleFilterButton.isHidden = !isSamplesTab || !hasActiveSampleFilters
        sampleQueryBuilderButton.title = hasActiveSampleFilters ? "Edit Sample Query..." : "Sample Query..."
    }

    @objc func clearSampleFilter(_ sender: Any) {
        sampleFilterText = ""
        activeSampleTokens.removeAll()
        selectedSampleGroupId = nil
        updateChipStates()
        updateDisplayedSamples()
    }

    @objc func sampleTokenToggled(_ sender: NSButton) {
        guard let token = sampleTokenPayloads[ObjectIdentifier(sender)] else { return }
        if sender.state == .on {
            if let group = token.exclusivityGroupKey {
                for existing in activeSampleTokens where existing != token && existing.exclusivityGroupKey == group {
                    activeSampleTokens.remove(existing)
                }
            }
            activeSampleTokens.insert(token)
        } else {
            activeSampleTokens.remove(token)
        }
        updateChipStates()
        updateDisplayedSamples()
    }

    @objc func openSampleSearchBuilder(_ sender: Any) {
        guard activeTab == .samples, let hostWindow = self.window else { return }
        let builderView = SampleQueryBuilderView(
            initialFilterText: sampleFilterText,
            metadataFields: sampleMetadataFields,
            onApply: { [weak self] filterText in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sampleFilterText = filterText
                        self.updateChipStates()
                        self.updateDisplayedSamples()
                        hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
                    }
                }
            },
            onCancel: {
                hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
            }
        )

        let hostingController = NSHostingController(rootView: builderView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Sample Query Builder"
        hostWindow.beginSheet(sheetWindow)
    }

    func rebuildSampleGroupPresetMenu() {
        sampleGroupPresetButton.removeAllItems()
        sampleGroupPresetButton.addItem(withTitle: "Group Presets")
        sampleGroupPresetButton.item(at: 0)?.isEnabled = false

        let groups = currentSampleDisplayState.sampleGroups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !groups.isEmpty else {
            sampleGroupPresetButton.isEnabled = false
            return
        }

        sampleGroupPresetButton.menu?.addItem(.separator())
        for group in groups {
            let item = NSMenuItem(title: group.name, action: #selector(selectSampleGroupPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id.uuidString
            sampleGroupPresetButton.menu?.addItem(item)
        }
        sampleGroupPresetButton.menu?.addItem(.separator())
        let clearItem = NSMenuItem(title: "Show All Samples", action: #selector(clearSampleGroupPreset(_:)), keyEquivalent: "")
        clearItem.target = self
        sampleGroupPresetButton.menu?.addItem(clearItem)
        sampleGroupPresetButton.isEnabled = true
    }

    @objc func selectSampleGroupPreset(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let group = currentSampleDisplayState.sampleGroups.first(where: { $0.id == id }) else { return }
        selectedSampleGroupId = id
        let shown = group.sampleNames
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !shown.contains($0) })
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func clearSampleGroupPreset(_ sender: NSMenuItem) {
        selectedSampleGroupId = nil
        currentSampleDisplayState.hiddenSamples.removeAll()
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    func applyAnnotationAdvancedFilters(
        _ results: [AnnotationSearchIndex.SearchResult],
        query: AnnotationFilterQuery
    ) -> [AnnotationSearchIndex.SearchResult] {
        results.filter { row in
            if let chr = query.chromosome, row.chromosome.caseInsensitiveCompare(chr) != .orderedSame { return false }
            if let strand = query.strand, row.strand.caseInsensitiveCompare(strand) != .orderedSame { return false }
            if let start = query.start, row.end <= start { return false }
            if let end = query.end, row.start >= end { return false }
            return true
        }
    }

    func applyVariantAdvancedFilters(
        _ results: [AnnotationSearchIndex.SearchResult],
        query: VariantFilterQuery
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

    /// Detects if the given text looks like a gene list (comma or newline-separated gene names).
    /// Returns the gene list if detected, nil otherwise.
    ///
    /// A gene list is detected when:
    /// - Text contains commas or newlines
    /// - All tokens are alphanumeric gene-like names (no operators like >, <, =, ;)
    /// - At least 2 tokens
    func detectGeneListPattern(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Must contain commas or newlines to be a gene list
        guard trimmed.contains(",") || trimmed.contains("\n") else { return nil }
        // Must not contain operators (filter syntax)
        guard !trimmed.contains(";"), !trimmed.contains(">"), !trimmed.contains("<"),
              !trimmed.contains("="), !trimmed.contains(":") else { return nil }

        let genes = trimmed
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard genes.count >= 2 else { return nil }
        return genes
    }

    func parseRange(_ text: String) -> (start: Int, end: Int)? {
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return nil }
        guard end > start else { return nil }
        return (start, end)
    }

    func parseRegion(_ text: String) -> (chromosome: String, start: Int, end: Int)? {
        let pieces = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
        guard let range = parseRange(pieces[1]) else { return nil }
        return (pieces[0], range.start, range.end)
    }

    func parseComparisonToken(_ token: String, keys: [String]) -> (op: String, value: Double)? {
        let operators = [">=", "<=", ">", "<"]
        for key in keys {
            for op in operators {
                let prefix = "\(key)\(op)"
                if token.lowercased().hasPrefix(prefix),
                   let value = Double(token.dropFirst(prefix.count)) {
                    return (op, value)
                }
            }
        }
        return nil
    }

    @objc func typeChipToggled(_ sender: NSButton) {
        let type = sender.title
        if sender.state == .on {
            visibleTypes.insert(type)
        } else {
            visibleTypes.remove(type)
        }
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc func selectAllTypes(_ sender: Any) {
        visibleTypes = Set(availableTypes)
        updateChipStates()
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc func selectNoTypes(_ sender: Any) {
        visibleTypes.removeAll()
        updateChipStates()
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc func openVariantSearchBuilder(_ sender: Any) {
        guard activeTab == .variants, let hostWindow = self.window else { return }
        guard !isMaterializedOnlyModeEnabled() else {
            NSSound.beep()
            return
        }

        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let infoDefs = infoColumnKeys.map { InfoKeyDefinition(key: $0.key, type: $0.type, description: $0.description) }
        let executionScopeLabel = viewportSyncEnabled
            ? "Execution Scope: Region (current viewport/region)"
            : "Execution Scope: Genome-wide"
        let builderView = VariantQueryBuilderView(
            initialFilterText: variantFilterText,
            availableInfoKeys: infoKeySet,
            infoKeyDefinitions: infoDefs,
            availableVariantTypes: availableVariantTypes,
            sampleNames: allSampleNames,
            savedPresets: savedQueryPresets,
            executionScopeLabel: executionScopeLabel,
            onApply: { [weak self] filterText in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.variantFilterText = filterText
                        self.markVariantFilterStateMutated()
                        self.updateVariantFilterIndicator()
                        self.updateChipStates()
                        self.updateDisplayedAnnotations()
                        hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
                    }
                }
            },
            onSavePreset: { [weak self] preset in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.savedQueryPresets.append(preset)
                    }
                }
            },
            onCancel: {
                hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
            }
        )

        let hostingController = NSHostingController(rootView: builderView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.title = "Query Builder"
        hostWindow.beginSheet(sheetWindow)
    }

}

private extension String {
    func value(after prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
