// AnnotationTableDrawerView+DeleteAndSampleData.swift - Variant deletion, the annotation to variant cross-reference and the sample tab data of the annotation drawer
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

extension AnnotationTableDrawerView {

    // MARK: - Delete Actions

    @objc func deleteSelectedVariantsAction(_ sender: NSMenuItem) {
        guard let source = searchIndex else { return }
        let selectedRows = commandSelectionIndexes
        let selectedVariants = selectedRows.compactMap { idx -> AnnotationSearchIndex.SearchResult? in
            guard idx < displayedAnnotations.count else { return nil }
            return displayedAnnotations[idx]
        }
        let scopedIDs = variantIDsByTrack(from: selectedVariants)
        let count = scopedIDs.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(count) Variant\(count == 1 ? "" : "s")?"
        alert.informativeText = "This will permanently remove the selected variant\(count == 1 ? "" : "s") from the database."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()
        alert.alertStyle = .warning

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.searchIndex === source else { return }
            self.performVariantDeletion(scopedIDs)
        }
    }

    @objc func deleteAllVariantsAction(_ sender: NSMenuItem) {
        guard let source = searchIndex else { return }
        let count = totalVariantCount
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        let alert = NSAlert()
        alert.messageText = "Delete All \(count) Variants?"
        alert.informativeText = "This will permanently remove all variants from the database. This cannot be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()
        alert.alertStyle = .critical

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.searchIndex === source else { return }
            self.performDeleteAllVariants()
        }
    }

    private func performVariantDeletion(_ idsByTrack: [String: [Int64]]) {
        guard let searchIndex else { return }
        guard !idsByTrack.isEmpty else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.error("performVariantDeletion: Could not resolve enclosing variant bundle for provenance")
            return
        }

        let targets = searchIndex.variantDatabaseHandles.map {
            VariantDeletionMutationTarget(
                trackId: $0.trackId,
                databaseURL: $0.db.databaseURL,
                trackName: searchIndex.variantTrackName(for: $0.trackId)
            )
        }
        let arguments = VariantDeletionMutationService.deleteSelectedArguments(bundleURL: bundleURL, idsByTrack: idsByTrack)
        runVariantStorageMutation(title: "Variant deletion", bundleURL: bundleURL, command: arguments, work: {
            try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
                idsByTrack: idsByTrack, bundleURL: bundleURL, targets: targets,
                invocationArgv: [LungfishAppIdentity.recordedToolName] + arguments, durableReplayArgv: [CLICommandIdentity.executableName] + arguments)
        }, publish: { [weak self] result in
            guard let self, result.totalDeleted > 0 else { return }
            self.totalVariantCount = max(0, self.totalVariantCount - result.totalDeleted)
            self.updateDisplayedAnnotations()
            self.updateCountLabel()
            self.delegate?.annotationDrawer(self, didDeleteVariants: result.totalDeleted)
        })
    }

    private func performDeleteAllVariants() {
        guard let searchIndex else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.error("performDeleteAllVariants: Could not resolve enclosing variant bundle for provenance")
            return
        }

        let targets = searchIndex.variantDatabaseHandles.map {
            VariantDeletionMutationTarget(
                trackId: $0.trackId,
                databaseURL: $0.db.databaseURL,
                trackName: searchIndex.variantTrackName(for: $0.trackId)
            )
        }
        let arguments = VariantDeletionMutationService.deleteAllArguments(bundleURL: bundleURL)
        runVariantStorageMutation(title: "Delete all variants", bundleURL: bundleURL, command: arguments, work: {
            try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteAllVariants(
                bundleURL: bundleURL, targets: targets,
                invocationArgv: [LungfishAppIdentity.recordedToolName] + arguments, durableReplayArgv: [CLICommandIdentity.executableName] + arguments)
        }, publish: { [weak self] result in
            guard let self, result.totalDeleted > 0 else { return }
            self.totalVariantCount = 0
            self.updateDisplayedAnnotations()
            self.updateCountLabel()
            self.delegate?.annotationDrawer(self, didDeleteVariants: result.totalDeleted)
        })
    }

    /// Groups selected variant row IDs by their owning track ID.
    func variantIDsByTrack(from variants: [AnnotationSearchIndex.SearchResult]) -> [String: [Int64]] {
        var grouped = Dictionary<String, Set<Int64>>()
        for variant in variants {
            guard variant.isVariant, !variant.trackId.isEmpty, let rowID = variant.variantRowId else { continue }
            grouped[variant.trackId, default: []].insert(rowID)
        }
        return grouped.mapValues { Array($0) }
    }

    // MARK: - Annotation→Variant Cross-Reference

    /// Computes a bounding region from the current annotation search results.
    /// Only sets the region if all displayed annotations are on the same chromosome.
    func updateAnnotationSearchRegion() {
        guard !displayedAnnotations.isEmpty else {
            annotationSearchRegion = nil
            return
        }

        // Only compute a meaningful region when filtering is active
        guard !annotationFilterText.isEmpty || visibleAnnotationTypes.count < availableAnnotationTypes.count else {
            annotationSearchRegion = nil
            return
        }

        // Group by chromosome, use the largest group
        var byChr: [String: (start: Int, end: Int)] = [:]
        for ann in displayedAnnotations {
            if let existing = byChr[ann.chromosome] {
                byChr[ann.chromosome] = (min(existing.start, ann.start), max(existing.end, ann.end))
            } else {
                byChr[ann.chromosome] = (ann.start, ann.end)
            }
        }

        // Pick the chromosome with the most annotations
        let primaryChr = byChr.max(by: { a, b in
            displayedAnnotations.filter { $0.chromosome == a.key }.count <
            displayedAnnotations.filter { $0.chromosome == b.key }.count
        })

        guard let chr = primaryChr else {
            annotationSearchRegion = nil
            return
        }

        annotationSearchRegion = (chromosome: chr.key, start: chr.value.start, end: chr.value.end)
    }

    @objc func showOverlappingVariantsAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        selectedAnnotationRegion = (chromosome: result.chromosome, start: result.start, end: result.end)
        if activeTab == .variants {
            // Already on variants tab — just refresh with the new region
            updateDisplayedAnnotations()
        } else {
            switchToTab(.variants)
        }
    }

    // MARK: - Sample Tab Data

    func sampleRowKey(name: String, sourceFile: String) -> String {
        "\(name)|\(sourceFile)"
    }

    nonisolated static func sourceFileMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Populates sample data from all variant database handles in the search index.
    func populateSampleData(from index: AnnotationSearchIndex) {
        allSampleNames = []
        allSampleRowKeys = []
        sampleNameByRowKey = [:]
        sampleMetadata = [:]
        sampleSourceFiles = [:]
        sampleDisplayNamesCache = [:]
        var metadataKeySet = Set<String>()
        var seenSampleNames = Set<String>()
        var seenRowKeys = Set<String>()

        for handle in index.variantDatabaseHandles {
            let db = handle.db
            let sourceBySample = db.allSourceFiles()
            let displayNames = db.allDisplayNames()

            let samples = db.allSampleMetadata()
            for (name, metadata) in samples {
                if seenSampleNames.insert(name).inserted {
                    allSampleNames.append(name)
                }
                let sourceFile = sourceBySample[name] ?? ""
                let rowKey = sampleRowKey(name: name, sourceFile: sourceFile)
                guard seenRowKeys.insert(rowKey).inserted else { continue }
                allSampleRowKeys.append(rowKey)
                sampleNameByRowKey[rowKey] = name
                sampleSourceFiles[rowKey] = sourceFile
                if let dn = displayNames[name] { sampleDisplayNamesCache[rowKey] = dn }
                if !metadata.isEmpty {
                    sampleMetadata[rowKey] = metadata
                    for key in metadata.keys {
                        metadataKeySet.insert(key)
                    }
                }
            }

            // If allSampleMetadata() returned empty, fall back to sampleNames()
            if samples.isEmpty {
                for name in db.sampleNames() {
                    if seenSampleNames.insert(name).inserted {
                        allSampleNames.append(name)
                    }
                    let sourceFile = sourceBySample[name] ?? ""
                    let rowKey = sampleRowKey(name: name, sourceFile: sourceFile)
                    guard seenRowKeys.insert(rowKey).inserted else { continue }
                    allSampleRowKeys.append(rowKey)
                    sampleNameByRowKey[rowKey] = name
                    sampleSourceFiles[rowKey] = sourceFile
                }
            }
        }

        sampleMetadataFields = metadataKeySet.sorted()
        if !hasSampleDisplayStateSeed {
            currentSampleDisplayState = Self.defaultSampleDisplayState()
        }
    }

    /// Updates the displayed samples list based on the current filter text and sample order.
    func updateDisplayedSamples() {
        let query = parseSampleFilterText(sampleFilterText)
        let freeText = query.textFilter.lowercased()

        displayedSamples = resolvedSampleOrder().compactMap { rowKey in
            guard let name = sampleNameByRowKey[rowKey] else { return nil }
            let sourceFile = sampleSourceFiles[rowKey] ?? ""
            let metadata = sampleMetadata[rowKey] ?? [:]
            let displayName = sampleDisplayNamesCache[rowKey]
            let isVisible = !currentSampleDisplayState.hiddenSamples.contains(name)

            // Apply text filter across name, source, and metadata values
            if !freeText.isEmpty {
                let searchText = ([name, displayName ?? "", sourceFile] + metadata.values).joined(separator: " ").lowercased()
                guard searchText.contains(freeText) else { return nil }
            }
            if let nameFilter = query.nameFilter,
               !sampleStringMatches(actual: name, op: nameFilter.op, expected: nameFilter.value) { return nil }
            if let sourceFilter = query.sourceFilter,
               !sampleStringMatches(actual: sourceFile, op: sourceFilter.op, expected: sourceFilter.value) { return nil }
            if let expectedVisibility = query.visibility, expectedVisibility != isVisible { return nil }
            for filter in query.metadataFilters {
                let actual = metadata[filter.field]
                    ?? metadata.first(where: { $0.key.caseInsensitiveCompare(filter.field) == .orderedSame })?.value
                    ?? ""
                if !sampleStringMatches(actual: actual, op: filter.op, expected: filter.value) { return nil }
            }

            // Token-based filters
            if activeSampleTokens.contains(.visibleOnly) && !isVisible { return nil }
            if activeSampleTokens.contains(.hiddenOnly) && isVisible { return nil }
            let hasSource = !sourceFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if activeSampleTokens.contains(.hasSource) && !hasSource { return nil }
            if activeSampleTokens.contains(.missingSource) && hasSource { return nil }

            if let selectedGroup = selectedSampleGroupId,
               let group = currentSampleDisplayState.sampleGroups.first(where: { $0.id == selectedGroup }),
               !group.sampleNames.contains(name) {
                return nil
            }

            return SampleDisplayRow(rowKey: rowKey, name: name, sourceFile: sourceFile, isVisible: isVisible, metadata: metadata, displayName: displayName)
        }

        // Propagate query-filtered sample subset to viewer genotype row visibility.
        syncSampleFilterVisibilityToViewer(query: query)

        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateSampleFilterIndicator()
        updateCountLabel()
    }

    func syncSampleFilterVisibilityToViewer(query: SampleFilterQuery) {
        let hasVisibilityConstraint =
            query.visibility != nil ||
            activeSampleTokens.contains(.visibleOnly) ||
            activeSampleTokens.contains(.hiddenOnly)
        let shouldSyncByQuery = hasActiveSampleFilters && !hasVisibilityConstraint

        if shouldSyncByQuery {
            if sampleFilterBaselineHiddenSamples == nil {
                sampleFilterBaselineHiddenSamples = currentSampleDisplayState.hiddenSamples
            }
            let shownNames = Set(displayedSamples.map(\.name))
            let desiredHidden = Set(allSampleNames.filter { !shownNames.contains($0) })
            if desiredHidden != currentSampleDisplayState.hiddenSamples {
                currentSampleDisplayState.hiddenSamples = desiredHidden
                postSampleDisplayStateChange()
            }
            return
        }

        if !hasActiveSampleFilters, let baseline = sampleFilterBaselineHiddenSamples {
            sampleFilterBaselineHiddenSamples = nil
            if baseline != currentSampleDisplayState.hiddenSamples {
                currentSampleDisplayState.hiddenSamples = baseline
                postSampleDisplayStateChange()
            }
        }
    }

    func sampleStringMatches(actual: String, op: String, expected: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)

        switch op {
        case "=":
            if normalizedExpected.isEmpty { return normalizedActual.isEmpty }  // "is empty"
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) == .orderedSame
        case "!=":
            if normalizedExpected.isEmpty { return !normalizedActual.isEmpty } // "is not empty"
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) != .orderedSame
        case "~", ":":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
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

    func annotationColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
        switch key {
        case "name":
            return row.name
        case "track_id":
            return row.trackId
        case "track_name":
            return annotationTrackName(for: row)
        case "type":
            return row.type
        case "chromosome":
            return row.chromosome
        case "start":
            // Column filters compare against the 1-based value the Start cell shows.
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

    func isAnnotationFilterNumericKey(_ key: String) -> Bool {
        switch key {
        case "start", "end", "size":
            return true
        default:
            if key.hasPrefix("attr_") {
                let attributeKey = String(key.dropFirst(5))
                return isNumericAnnotationAttributeKey(attributeKey)
            }
            return false
        }
    }

    func annotationTrackName(for row: AnnotationSearchIndex.SearchResult) -> String {
        row.trackName ?? annotationTrackDisplayNames[row.trackId] ?? row.trackId
    }

    func annotationColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAnnotationFilterNumericKey(key),
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
        return sampleStringMatches(actual: normalizedActual, op: op, expected: normalizedExpected)
    }

    func applyAnnotationColumnFilters(
        to rows: [AnnotationSearchIndex.SearchResult],
        clauses: [ColumnFilterClause]
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard !clauses.isEmpty else { return rows }
        return rows.filter { row in
            clauses.allSatisfy { clause in
                let actual = annotationColumnValue(row, key: clause.key)
                return annotationColumnMatches(actual: actual, op: clause.op, expected: clause.value, key: clause.key)
            }
        }
    }

    func applyAnnotationColumnFilters(to rows: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        applyAnnotationColumnFilters(to: rows, clauses: annotationColumnFilterClauses)
    }

    func setAnnotationBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedAnnotationRows = rows
        displayedAnnotations = applyAnnotationColumnFilters(to: rows)
        for row in rows {
            if let trackName = row.trackName, !trackName.isEmpty {
                annotationTrackDisplayNames[row.trackId] = trackName
            }
        }
        let availableTrackIDs = searchIndex?.annotationDatabaseHandles.map(\.trackId) ?? []
        syncAnnotationTracks(from: availableTrackIDs.isEmpty ? rows.map(\.trackId) : availableTrackIDs)
    }

    func applyAnnotationColumnFiltersFromBase() {
        displayedAnnotations = applyAnnotationColumnFilters(to: baseDisplayedAnnotationRows)
        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateAnnotationSearchRegion()
        updateCountLabel()
    }

    func variantColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
        switch key {
        case "variant_id":
            return row.name
        case "variant_type":
            return row.type
        case "chromosome":
            return row.chromosome
        case "position":
            return String(row.start + 1)
        case "ref":
            return row.ref ?? ""
        case "alt":
            return row.alt ?? ""
        case "quality":
            return row.quality.map { String($0) } ?? ""
        case "filter":
            return row.filter ?? ""
        case "samples":
            return row.sampleCount.map { String($0) } ?? ""
        case "source":
            return row.sourceFile ?? ""
        case "track_name":
            return row.trackName ?? searchIndex?.variantTrackName(for: row.trackId) ?? row.trackId
        case "caller_settings":
            return searchIndex?.variantCallerSettings(for: row.trackId) ?? "Not recorded"
        case "coding_feature":
            return variantCodingFeatureText(for: row)
        case "consequence":
            return variantConsequenceText(for: row)
        case "aa_change":
            return variantAAChangeText(for: row)
        default:
            if key.hasPrefix("info_") {
                let infoKey = String(key.dropFirst(5))
                return row.infoDict?[infoKey] ?? ""
            }
            return ""
        }
    }

    /// Resolves Inspector values through the same column presentation path as
    /// the table, including caller settings and derived coding annotations.
    func variantInspectorFields(
        for row: AnnotationSearchIndex.SearchResult
    ) -> [VariantInspectorField] {
        Self.variantColumnDefs.map { definition in
            VariantInspectorField(
                key: definition.4,
                label: definition.1,
                value: variantColumnValue(row, key: definition.4)
            )
        }
    }

    func variantColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedExpected.isEmpty {
            switch op {
            case "=": return normalizedActual.isEmpty
            case "!=": return !normalizedActual.isEmpty
            default: break
            }
        }
        if isVariantFilterNumericKey(key) {
            guard let lhs = Double(normalizedActual), let rhs = Double(normalizedExpected) else {
                return false
            }
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
        return sampleStringMatches(actual: normalizedActual, op: op, expected: normalizedExpected)
    }

    func applyVariantColumnFilters(to rows: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        return rows.filter { row in
            guard !hiddenVariantTrackIDs.contains(row.trackId) else { return false }
            return variantColumnFilterClauses.allSatisfy { clause in
                let actual = variantColumnValue(row, key: clause.key)
                return variantColumnMatches(actual: actual, op: clause.op, expected: clause.value, key: clause.key)
            }
        }
    }

    func setVariantBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedVariantAnnotations = rows
        fallbackConsequenceCache = [:]
        displayedAnnotations = applyVariantColumnFilters(to: rows)
        sortDisplayedVariantCallsIfNeeded()
    }

    func applyVariantColumnFiltersFromBase() {
        let selectedVariantIdentities = selectedVariantCallSelectionIdentities()
        let wasSuppressingDelegateCallbacks = isSuppressingDelegateCallbacks
        isSuppressingDelegateCallbacks = true
        defer {
            restoreVariantCallSelection(selectedVariantIdentities)
            isSuppressingDelegateCallbacks = wasSuppressingDelegateCallbacks
            if !wasSuppressingDelegateCallbacks {
                publishCurrentVariantSelection()
            }
        }
        displayedAnnotations = applyVariantColumnFilters(to: baseDisplayedVariantAnnotations)
        sortDisplayedVariantCallsIfNeeded()
        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateCountLabel()
        if activeVariantSubtab == .genotypes {
            buildGenotypeRows()
        }
    }

    func setHiddenVariantTrackIDs(_ ids: Set<String>) {
        guard hiddenVariantTrackIDs != ids else { return }
        hiddenVariantTrackIDs = ids
        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()
        activeVariantQueryCancelToken = nil
        variantQueryGeneration += 1
        cachedGlobalFilteredVariantRows = []
        cachedGlobalFilteredVariantKey = nil
        applyVariantColumnFiltersFromBase()
        if activeTab == .variants, searchIndex != nil {
            updateDisplayedAnnotations()
        }
    }

    func emitVisibleVariantRenderKeyUpdateIfNeeded() {
        // During async query churn, keep the last stable viewport sync set only
        // while there are no stable rows to mirror yet.
        if activeTab == .variants && isVariantQuerying && (scrollView.isHidden || displayedAnnotations.isEmpty) {
            return
        }
        if activeTab == .variants && isVariantQuerying && !scrollView.isHidden && !displayedAnnotations.isEmpty {
            // Safety: if rows are visible, query progress should no longer block sync.
            hideVariantQueryProgress()
        }

        let keysToEmit: Set<String>?
        if activeTab == .variants {
            if scrollView.isHidden {
                // Placeholder / too-many state: no stable table rows to mirror.
                // Clear sync filter so zooming back in can recover naturally.
                keysToEmit = nil
            } else {
                keysToEmit = Set(displayedAnnotations.compactMap { result in
                    guard let rowId = result.variantRowId, !result.trackId.isEmpty else { return nil }
                    return "\(result.trackId):\(rowId)"
                })
            }
        } else {
            keysToEmit = nil
        }
        localVariantFilterBadgeLabel.stringValue = variantColumnFilterClauses.isEmpty
            ? "Table Sync: Visible Rows"
            : "Local: Visible Rows"
        guard keysToEmit != lastEmittedVisibleVariantRenderKeys else { return }
        lastEmittedVisibleVariantRenderKeys = keysToEmit
        delegate?.annotationDrawer(self, didUpdateVisibleVariantRenderKeys: keysToEmit)
    }

    func emitVisibleAnnotationRenderKeyUpdateIfNeeded() {
        let keysToEmit: Set<String>?
        if activeTab == .annotations && annotationViewportFilterEnabled && !scrollView.isHidden {
            keysToEmit = Set(displayedAnnotations.compactMap { result in
                guard !result.trackId.isEmpty, let rowID = result.annotationRowId else { return nil }
                return "\(result.trackId):\(rowID)"
            })
        } else {
            keysToEmit = nil
        }
        guard keysToEmit != lastEmittedVisibleAnnotationRenderKeys else { return }
        lastEmittedVisibleAnnotationRenderKeys = keysToEmit
        delegate?.annotationDrawer(self, didUpdateVisibleAnnotationRenderKeys: keysToEmit)
    }

    /// Returns sample row keys in effective display order (persisted order + any new rows).
    func resolvedSampleOrder() -> [String] {
        guard let order = currentSampleDisplayState.sampleOrder else { return allSampleRowKeys }
        let allSet = Set(allSampleRowKeys)
        var ordered = order.filter { allSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: allSampleRowKeys.filter { !orderedSet.contains($0) })
        return ordered
    }

    /// Sorts sample row keys by samples-tab column key.
    func sortedSampleNames(key: String, ascending: Bool, names: [String]) -> [String] {
        names.sorted { rowKeyA, rowKeyB in
            let nameA = sampleNameByRowKey[rowKeyA] ?? ""
            let nameB = sampleNameByRowKey[rowKeyB] ?? ""
            let metaA = sampleMetadata[rowKeyA] ?? [:]
            let metaB = sampleMetadata[rowKeyB] ?? [:]
            let sourceA = sampleSourceFiles[rowKeyA] ?? ""
            let sourceB = sampleSourceFiles[rowKeyB] ?? ""
            let visibleA = !currentSampleDisplayState.hiddenSamples.contains(nameA)
            let visibleB = !currentSampleDisplayState.hiddenSamples.contains(nameB)
            let result: ComparisonResult
            switch key {
            case "visible":
                result = visibleA == visibleB ? .orderedSame : (visibleA ? .orderedAscending : .orderedDescending)
            case "sample_name":
                result = nameA.localizedCaseInsensitiveCompare(nameB)
            case "display_name":
                let displayA = (sampleDisplayNamesCache[rowKeyA] ?? nameA).trimmingCharacters(in: .whitespacesAndNewlines)
                let displayB = (sampleDisplayNamesCache[rowKeyB] ?? nameB).trimmingCharacters(in: .whitespacesAndNewlines)
                result = displayA.localizedCaseInsensitiveCompare(displayB)
            case "source_file":
                result = sourceA.localizedCaseInsensitiveCompare(sourceB)
            default:
                if key.hasPrefix("meta_") {
                    let metaKey = String(key.dropFirst(5))
                    let valA = metaA[metaKey] ?? ""
                    let valB = metaB[metaKey] ?? ""
                    result = valA.localizedCaseInsensitiveCompare(valB)
                } else {
                    result = .orderedSame
                }
            }
            if result == .orderedSame {
                if nameA.caseInsensitiveCompare(nameB) == .orderedSame {
                    return rowKeyA.localizedCaseInsensitiveCompare(rowKeyB) == .orderedAscending
                }
                return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Creates a cell view for the samples tab.
    func sampleCellView(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> NSView? {
        guard row < displayedSamples.count else { return nil }
        let sample = displayedSamples[row]

        // Checkbox column for visibility
        if identifier == Self.sampleVisibleColumn {
            let checkboxId = NSUserInterfaceItemIdentifier("SampleCheckbox")
            let checkbox: NSButton
            if let existing = tableView.makeView(withIdentifier: checkboxId, owner: nil) as? NSButton {
                checkbox = existing
            } else {
                checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(sampleVisibilityToggled(_:)))
                checkbox.identifier = checkboxId
                checkbox.controlSize = .small
            }
            checkbox.state = sample.isVisible ? .on : .off
            checkbox.tag = row
            return checkbox
        }

        let isMetaColumn = identifier.rawValue.hasPrefix("meta_")
        let isEditableColumn = isMetaColumn || identifier == Self.sampleDisplayNameColumn

        // Text cell for all other columns
        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf: NSTextField
            if isEditableColumn {
                // Editable text field for metadata and display name columns
                tf = NSTextField(string: "")
                tf.isBordered = false
                tf.drawsBackground = false
                tf.focusRingType = .exterior
                tf.delegate = self
            } else {
                tf = NSTextField(labelWithString: "")
            }
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let tf = cellView.textField!
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        switch identifier {
        case Self.sampleNameColumn:
            tf.stringValue = sample.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
        case Self.sampleDisplayNameColumn:
            tf.stringValue = sample.displayName ?? ""
            tf.placeholderString = sample.name
            tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
            tf.tag = row
        case Self.sampleSourceColumn:
            tf.stringValue = sample.sourceFile
            tf.font = .systemFont(ofSize: 11)
            tf.textColor = sample.isVisible ? .secondaryLabelColor : .tertiaryLabelColor
        default:
            // Dynamic metadata columns (identifier starts with "meta_")
            if isMetaColumn {
                let metaKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = sample.metadata[metaKey] ?? ""
                tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
                tf.placeholderString = "Click to edit"
                // Store row in tag for identification during editing
                tf.tag = row
            } else {
                tf.stringValue = ""
            }
        }

        return cellView
    }
}
