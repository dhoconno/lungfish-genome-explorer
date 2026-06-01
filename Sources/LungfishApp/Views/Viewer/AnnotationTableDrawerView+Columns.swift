// AnnotationTableDrawerView+Columns.swift - Extracted from AnnotationTableDrawerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import os.log

extension AnnotationTableDrawerView {

    // MARK: - Chip Button Factory

    func configureSearchField(_ field: NSSearchField, placeholder: String, accessibilityLabel: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.translatesAutoresizingMaskIntoConstraints = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterFieldChanged(_:))
        field.setAccessibilityLabel(accessibilityLabel)
        field.isHidden = true
    }

    func updateVariantToolbarDensity() {
        let density = Self.variantToolbarDensity(forWidth: bounds.width)
        let densityChanged = appliedVariantToolbarDensity != density
        appliedVariantToolbarDensity = density

        if densityChanged {
            switch density {
            case .full:
                scopeControl.setLabel("Region", forSegment: 0)
                scopeControl.setLabel("Genome", forSegment: 1)
                scopeControl.setWidth(62, forSegment: 0)
                scopeControl.setWidth(66, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("Genotypes", forSegment: 1)
                variantSubtabControl.setWidth(55, forSegment: 0)
                variantSubtabControl.setWidth(75, forSegment: 1)
                searchBuilderButton.title = "Search Builder..."
                clearFilterButton.title = "Clear"
            case .compact:
                scopeControl.setLabel("Region", forSegment: 0)
                scopeControl.setLabel("Genome", forSegment: 1)
                scopeControl.setWidth(56, forSegment: 0)
                scopeControl.setWidth(60, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("GT", forSegment: 1)
                variantSubtabControl.setWidth(50, forSegment: 0)
                variantSubtabControl.setWidth(36, forSegment: 1)
                searchBuilderButton.title = "Query"
                clearFilterButton.title = "Clear"
            case .minimal:
                scopeControl.setLabel("Reg", forSegment: 0)
                scopeControl.setLabel("Gen", forSegment: 1)
                scopeControl.setWidth(42, forSegment: 0)
                scopeControl.setWidth(42, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("GT", forSegment: 1)
                variantSubtabControl.setWidth(46, forSegment: 0)
                variantSubtabControl.setWidth(34, forSegment: 1)
                searchBuilderButton.title = "Query"
                clearFilterButton.title = "Clear"
            }
        }

        presetFiltersToggleButton.title = showVariantPresetChips ? "Presets ▾" : (density == .full ? "Presets ▸" : "Presets")
        let hasFilter = !variantFilterText.isEmpty || !activeSmartTokens.isEmpty || !selectedVariantPresetByKey.isEmpty
        searchBuilderButton.title = density == .full
            ? (hasFilter ? "Edit Query..." : "Query Builder...")
            : (hasFilter ? "Edit" : "Query")
    }

    func updateSearchFieldVisibility() {
        let showVariants = activeTab == .variants
        let showSamples = activeTab == .samples
        let totalVariantDBSize = totalVariantDatabaseSizeBytes()
        let isLargeDatabase = totalVariantDBSize >= Self.chromosomeScopeThreshold
        let isMaterializedOnlyDatabase = totalVariantDBSize >= Self.materializedOnlyThreshold
        let toolbarDensity = Self.variantToolbarDensity(forWidth: bounds.width)
        if showVariants {
            enforceMaterializedOnlyRestrictionsIfNeeded()
        }
        updateVariantToolbarDensity()
        annotationFilterField.isHidden = activeTab != .annotations
        annotationViewportFilterButton.isHidden = activeTab != .annotations
        annotationViewportFilterButton.state = annotationViewportFilterEnabled ? .on : .off
        annotationTracksButton.isHidden = activeTab != .annotations || annotationTrackOrder.isEmpty
        variantFilterField.isHidden = true  // Always hidden; Query Builder writes to variantFilterText directly
        sampleFilterField.isHidden = true  // Samples use Query Builder; free-text field hidden to reduce toolbar density
        addSampleFieldButton.isHidden = !showSamples
        sampleGroupsButton.isHidden = !showSamples
        importMetadataButton.isHidden = !showSamples
        downloadTemplateButton.isHidden = !showSamples
        sampleQueryBuilderButton.isHidden = !showSamples
        sampleGroupPresetButton.isHidden = !showSamples
        clearSampleFilterButton.isHidden = !showSamples || (!hasActiveSampleFilters && sampleFilterText.isEmpty)
        variantSubtabControl.isHidden = !showVariants
        profileButton.isHidden = !showVariants || toolbarDensity != .full
        scopeControl.isHidden = !showVariants
        haploidModeButton.isHidden = !showVariants || toolbarDensity == .minimal
        presetFiltersToggleButton.isHidden = !showVariants || toolbarDensity == .minimal || infoColumnKeys.isEmpty || isMaterializedOnlyDatabase
        presetFiltersToggleButton.isEnabled = variantPresetLoadState != .loading
        // Gate Query Builder on database size.
        let queryBuilderVisible: Bool = {
            guard showVariants else { return false }
            if isMaterializedOnlyDatabase {
                return false
            }
            if isLargeDatabase {
                // Large database: only show if viewport is < 10 Mb
                if let vp = viewportRegion {
                    return (vp.end - vp.start) < 10_000_000
                }
                return false
            }
            return true
        }()
        // Show button whenever variants tab is active; disable when query would be too slow
        searchBuilderButton.isHidden = !showVariants
        searchBuilderButton.isEnabled = queryBuilderVisible
        localVariantFilterBadgeLabel.isHidden = !showVariants || toolbarDensity == .minimal
        if !queryBuilderVisible && showVariants {
            let dbSizeMB = totalVariantDBSize / 1_000_000
            if isMaterializedOnlyDatabase {
                searchBuilderButton.toolTip = "Database is very large (\(dbSizeMB) MB). Query Builder is disabled; use Smart Token filters only."
            } else {
                searchBuilderButton.toolTip = "Database is large (\(dbSizeMB) MB). Zoom in to a region < 10 Mb to enable Query Builder."
            }
        } else {
            searchBuilderButton.toolTip = nil
        }
        let showTypeControls = activeTab != .samples && !availableTypes.isEmpty
        allTypesButton.isHidden = !showTypeControls || toolbarDensity == .minimal
        noneTypesButton.isHidden = !showTypeControls || toolbarDensity == .minimal
        updateVariantFilterIndicator()
        rebuildSampleGroupPresetMenu()
        updateScopeControlSelection()
    }

    func totalVariantDatabaseSizeBytes() -> UInt64 {
        var total: UInt64 = 0
        for url in variantTrackDatabaseURLs {
            total += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        return total
    }

    func isMaterializedOnlyModeEnabled() -> Bool {
        totalVariantDatabaseSizeBytes() >= Self.materializedOnlyThreshold
    }

    func isMaterializedTokenAllowedInStrictMode(_ token: SmartToken) -> Bool {
        guard isMaterializedOnlyModeEnabled() else { return true }
        return materializedTokenNamesAcrossTracks.contains(token.rawValue)
    }

    func enforceMaterializedOnlyRestrictionsIfNeeded() {
        guard isMaterializedOnlyModeEnabled() else { return }

        var changed = false
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variantFilterText = ""
            changed = true
        }
        if !selectedVariantPresetByKey.isEmpty {
            selectedVariantPresetByKey.removeAll()
            changed = true
        }

        let unsupportedTokens = activeSmartTokens.filter { !isMaterializedTokenAllowedInStrictMode($0) }
        if !unsupportedTokens.isEmpty {
            activeSmartTokens.subtract(unsupportedTokens)
            changed = true
        }

        if changed {
            markVariantFilterStateMutated()
            updateChipStates()
        }
    }

    func updateScopeControlSelection() {
        scopeControl.selectedSegment = viewportSyncEnabled ? 0 : 1
    }

    /// Updates the Search Builder button title and Clear button visibility
    /// based on whether a variant filter is active.
    func updateVariantFilterIndicator() {
        let hasFilter = !variantFilterText.isEmpty || !activeSmartTokens.isEmpty || !selectedVariantPresetByKey.isEmpty
        let toolbarDensity = Self.variantToolbarDensity(forWidth: bounds.width)
        clearFilterButton.isHidden = !(activeTab == .variants && hasFilter)
        if toolbarDensity == .full {
            searchBuilderButton.title = hasFilter ? "Edit Query..." : "Query Builder..."
        } else {
            searchBuilderButton.title = hasFilter ? "Edit" : "Query"
        }
        updateVariantLogicSummary()
    }

    @objc func clearVariantFilter(_ sender: Any) {
        variantFilterText = ""
        activeSmartTokens.removeAll()
        selectedVariantPresetByKey.removeAll()
        selectedAnnotationRegion = nil
        markVariantFilterStateMutated()
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    func makeTypeChipButton(type: String) -> NSButton {
        let button = NSButton(title: type, target: self, action: #selector(typeChipToggled(_:)))
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = .recessed
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.state = .on  // All types visible by default
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Toggle \(type) annotations")
        return button
    }

    func makeSmartTokenChipButton(token: SmartToken) -> NSButton {
        var label = token.label
        if let count = smartTokenCounts[token.rawValue], count > 0 {
            label += " (\(Self.formatCompactCount(count)))"
        }
        let button = NSButton(title: label, target: self, action: #selector(smartTokenToggled(_:)))
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = token.exclusivityGroupKey == nil ? .recessed : .rounded
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.state = activeSmartTokens.contains(token) ? .on : .off
        button.translatesAutoresizingMaskIntoConstraints = false
        var toolTip = "\(token.uiSection.title): \(token.label)"
        if let count = smartTokenCounts[token.rawValue] {
            toolTip += " — \(Self.formatCompactCount(count)) variants"
        }
        if token.exclusivityGroupKey != nil {
            toolTip += " (mutually exclusive)"
        }
        button.toolTip = toolTip
        return button
    }

    /// Formats a count into a compact human-readable string (e.g., 1234567 → "1.2M").
    static func formatCompactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions >= 10 ? String(format: "%.0fM", millions) : String(format: "%.1fM", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000
            return thousands >= 10 ? String(format: "%.0fK", thousands) : String(format: "%.1fK", thousands)
        }
        return "\(count)"
    }

    func updateVariantLogicSummary() {
        guard activeTab == .variants else {
            chipSummaryLabel.isHidden = true
            return
        }

        var parts: [String] = []
        parts.append(viewportSyncEnabled ? "region follow enabled" : "genome scope")
        if !activeSmartTokens.isEmpty {
            parts.append("tokens: \(activeSmartTokens.map(\.label).sorted().joined(separator: ", "))")
        }
        if !selectedVariantPresetByKey.isEmpty {
            let values = selectedVariantPresetByKey.keys.sorted().compactMap { key in
                selectedVariantPresetByKey[key].map { "\(key)=\($0)" }
            }.joined(separator: ", ")
            if !values.isEmpty {
                parts.append("preset filters: \(values)")
            }
        }
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("query builder rules active")
        }
        if !availableVariantTypes.isEmpty && visibleVariantTypes.count < availableVariantTypes.count {
            parts.append("types: \(visibleVariantTypes.count)/\(availableVariantTypes.count)")
        }

        chipSummaryLabel.stringValue = parts.isEmpty
            ? "Current logic: no filters (all variants)"
            : "Current logic: " + parts.joined(separator: "  •  ")
        chipSummaryLabel.isHidden = false
    }

    // MARK: - Column Configuration

    /// Column definitions for the annotation tab.
    static let annotationColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (nameColumn, "Name", 180, 80, "name"),
        (trackNameColumn, "Track Name", 140, 80, "track_name"),
        (trackIdColumn, "Track ID", 130, 70, "track_id"),
        (typeColumn, "Type", 80, 50, "type"),
        (chromosomeColumn, "Chromosome", 120, 60, "chromosome"),
        (startColumn, "Start", 100, 60, "start"),
        (endColumn, "End", 100, 60, "end"),
        (sizeColumn, "Size", 80, 50, "size"),
        (strandColumn, "Strand", 50, 30, "strand"),
    ]

    /// Column definitions for the variant tab.
    static let variantColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (variantIdColumn, "ID", 130, 70, "variant_id"),
        (variantTypeColumn, "Type", 60, 40, "variant_type"),
        (variantChromColumn, "Chrom", 80, 50, "chromosome"),
        (positionColumn, "Position", 90, 60, "position"),
        (refColumn, "Ref", 60, 30, "ref"),
        (altColumn, "Alt", 60, 30, "alt"),
        (qualityColumn, "Quality", 70, 40, "quality"),
        (filterColumn, "Filter", 70, 40, "filter"),
        (samplesColumn, "Samples", 60, 40, "samples"),
        (sourceColumn, "Source", 100, 60, "source"),
        (consequenceColumn, "Consequence", 170, 90, "consequence"),
        (aaChangeColumn, "AA Change", 120, 80, "aa_change"),
    ]

    /// Column definitions for the samples tab (fixed columns — metadata columns are dynamic).
    static let sampleColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (sampleVisibleColumn, "", 30, 30, "visible"),
        (sampleNameColumn, "Sample", 180, 80, "sample_name"),
        (sampleDisplayNameColumn, "Display Name", 150, 80, "display_name"),
        (sampleSourceColumn, "Source", 140, 60, "source_file"),
    ]

    /// Removes all existing columns and adds columns for the specified tab.
    func configureColumnsForTab(_ tab: DrawerTab) {
        // Remove existing columns
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }

        let defs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)]
        switch tab {
        case .annotations: defs = Self.annotationColumnDefs
        case .variants: defs = Self.variantColumnDefs
        case .samples: defs = Self.sampleColumnDefs
        }

        for (identifier, title, width, minWidth, sortKey) in defs {
            let col = NSTableColumn(identifier: identifier)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.resizingMask = [.autoresizingMask, .userResizingMask]
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: sortKey, ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
            tableView.addTableColumn(col)
        }

        if tab == .annotations {
            for key in annotationAttributeColumnKeys {
                addAnnotationAttributeColumn(key)
            }
        }

        // Add dynamic INFO columns for variants tab.
        // Promoted keys (AF, Gene, Impact) are inserted right after fixed columns
        // so they appear in a biologically useful default order. Remaining INFO
        // columns follow in their original discovery order.
        if tab == .variants {
            let promotedKeys = Self.promotedInfoKeys(from: infoColumnKeys)
            let promotedKeySet = Set(promotedKeys.map(\.key))

            // Phase 1: promoted keys in expert-recommended order
            for info in promotedKeys {
                addInfoColumn(info)
            }

            // Phase 2: remaining keys in discovery order
            for info in infoColumnKeys where !promotedKeySet.contains(info.key) {
                addInfoColumn(info)
            }
        }

        // Add dynamic metadata columns for samples tab
        if tab == .samples {
            for field in sampleMetadataFields {
                let identifier = NSUserInterfaceItemIdentifier("meta_\(field)")
                let col = NSTableColumn(identifier: identifier)
                col.title = field.capitalized
                col.width = max(60, CGFloat(field.count) * 8)
                col.minWidth = 40
                col.resizingMask = [.autoresizingMask, .userResizingMask]
                col.sortDescriptorPrototype = NSSortDescriptor(
                    key: "meta_\(field)", ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
                tableView.addTableColumn(col)
            }
        }

        // Add bookmark column for variants tab (before saved prefs so it persists across reconfigs)
        if tab == .variants {
            addBookmarkColumnIfNeeded()
        }

        // Apply saved column preferences (visibility + ordering)
        if let saved = ColumnPrefsKey.load(tab: tab.prefsKey) {
            let hiddenIds = Set(saved.columns.filter { !$0.isVisible }.map(\.id))
            for col in tableView.tableColumns.reversed() {
                if hiddenIds.contains(col.identifier.rawValue) {
                    tableView.removeTableColumn(col)
                }
            }
            // Reorder visible columns to match saved order
            let orderedIds = saved.visibleColumns.map(\.id)
            for (targetIndex, colId) in orderedIds.enumerated() {
                if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colId }),
                   currentIndex != targetIndex, targetIndex < tableView.tableColumns.count {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        } else if tab == .samples {
            // Default behavior: keep only metadata columns with at least one non-empty value.
            let fieldsWithValues = metadataFieldsWithValues()
            for col in tableView.tableColumns.reversed() where col.identifier.rawValue.hasPrefix("meta_") {
                let field = String(col.identifier.rawValue.dropFirst(5))
                if !fieldsWithValues.contains(field) {
                    tableView.removeTableColumn(col)
                }
            }
        }
    }

    static let promotedAnnotationAttributeKeys = [
        "source_coordinates",
        "alignment_columns",
        "consensus_columns",
        "alignment_row",
        "source_sequence",
        "source_track",
        "origin",
        "read_name",
        "mapq",
        "cigar",
        "flag",
        "tag_NM",
        "tag_AS",
        "read_group",
        "source_alignment_track_name",
    ]

    static func orderedAnnotationAttributeKeys(
        from results: [AnnotationSearchIndex.SearchResult]
    ) -> [String] {
        let discovered = Set(
            results
                .filter { !$0.isVariant }
                .flatMap { result in
                    result.attributes?.compactMap { key, value in
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key
                    } ?? []
                }
        )
        let promoted = promotedAnnotationAttributeKeys.filter { discovered.contains($0) }
        let remaining = discovered.subtracting(promoted).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return promoted + remaining
    }

    func addAnnotationAttributeColumn(_ key: String) {
        let identifier = NSUserInterfaceItemIdentifier("attr_\(key)")
        let col = NSTableColumn(identifier: identifier)
        let title = Self.annotationAttributeDisplayTitle(for: key)
        col.title = title
        col.headerToolTip = "Annotation attribute: \(title)"
        col.width = max(70, CGFloat(title.count + 2) * 7)
        col.minWidth = 40
        col.resizingMask = [.autoresizingMask, .userResizingMask]
        col.sortDescriptorPrototype = NSSortDescriptor(
            key: "attr_\(key)", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        tableView.addTableColumn(col)
    }

    static func annotationAttributeDisplayTitle(for key: String) -> String {
        switch key {
        case "source_coordinates": return "Source Coordinates"
        case "alignment_columns": return "Alignment Columns"
        case "consensus_columns": return "Consensus Columns"
        case "alignment_row": return "Alignment Row"
        case "source_sequence": return "Source Sequence"
        case "source_track": return "Source Track"
        case "source_file": return "Source File"
        case "row_id": return "Row ID"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    word.count <= 3 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    func metadataFieldsWithValues() -> Set<String> {
        var fields = Set<String>()
        for metadata in sampleMetadata.values {
            for (key, value) in metadata {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fields.insert(key)
                }
            }
        }
        return fields
    }

    /// INFO keys that should be promoted to default-visible positions when present.
    /// Order matches the expert-recommended column layout:
    /// ... fixed columns ... | AF | Gene | Impact | ... remaining INFO ...
    static let promotedInfoKeyPatterns: [(displayTitle: String, keys: [String])] = [
        ("AF", ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF"]),
        ("Gene", ["GENE", "Gene", "gene", "GENEINFO", "ANN_Gene", "CSQ_SYMBOL"]),
        ("Impact", ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"]),
    ]

    /// Returns the subset of `infoColumnKeys` that match promoted patterns, in display order.
    static func promotedInfoKeys(
        from infoColumnKeys: [(key: String, type: String, description: String)]
    ) -> [(key: String, type: String, description: String)] {
        let keySet = Set(infoColumnKeys.map(\.key))
        var result: [(key: String, type: String, description: String)] = []
        for pattern in promotedInfoKeyPatterns {
            // Take the first matching key variant that exists in this VCF
            if let matchingKey = pattern.keys.first(where: { keySet.contains($0) }),
               let info = infoColumnKeys.first(where: { $0.key == matchingKey }) {
                result.append(info)
            }
        }
        return result
    }

    /// Adds a single INFO column to the table view.
    func addInfoColumn(_ info: (key: String, type: String, description: String)) {
        let identifier = NSUserInterfaceItemIdentifier("info_\(info.key)")
        let col = NSTableColumn(identifier: identifier)
        col.title = info.key
        let fullName = info.description.isEmpty ? info.key : "\(info.description) (\(info.key))"
        col.headerToolTip = fullName
        col.width = max(80, CGFloat(info.key.count + 2) * 7)
        col.minWidth = 40
        col.resizingMask = [.autoresizingMask, .userResizingMask]
        col.sortDescriptorPrototype = NSSortDescriptor(
            key: "info_\(info.key)", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        tableView.addTableColumn(col)
    }

    // MARK: - Tab Switching

    @objc func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = DrawerTab(rawValue: sender.selectedSegment) else { return }
        switchToTab(tab)
    }

    @objc func variantSubtabChanged(_ sender: NSSegmentedControl) {
        guard let subtab = VariantSubtab(rawValue: sender.selectedSegment) else { return }
        activeVariantSubtab = subtab
        if subtab == .genotypes {
            configureColumnsForGenotypes()
            buildGenotypeRows()
        } else {
            configureColumnsForTab(.variants)
            tableView.reloadData()
            updateCountLabel()
        }
    }

    @objc func scopeSegmentChanged(_ sender: NSSegmentedControl) {
        viewportSyncEnabled = (sender.selectedSegment == 0)
        markVariantFilterStateMutated()
        updateScopeControlSelection()
        updateVariantLogicSummary()
        // Re-query with new scope
        updateDisplayedAnnotations()
    }

    @objc func haploidModeChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0 else { return }
        let selected = sender.selectedTag()
        switch selected {
        case 1:
            haploidModeSelection = .haploid
        case 2:
            haploidModeSelection = .diploid
        default:
            haploidModeSelection = .auto
        }
        applyHaploidModeSelectionToIndex()
        saveHaploidModeSelection(haploidModeSelection, bundleIdentifier: searchIndex?.bundleIdentifier)
        isHaploidOrganism = searchIndex?.isLikelyHaploidOrganism ?? false
        currentSampleDisplayState.useHaploidAFShading = isHaploidOrganism
        postSampleDisplayStateChange()
        rebuildHaploidModeMenu()
        rebuildChipButtons()
        if activeTab == .variants, activeVariantSubtab == .genotypes {
            configureColumnsForGenotypes()
            tableView.reloadData()
        }
        if activeTab == .variants {
            updateDisplayedAnnotations()
        }
    }

    func haploidModeDefaultsKey(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return "VariantHaploidMode.\(bundleIdentifier)"
    }

    func loadHaploidModeSelection(bundleIdentifier: String?) -> HaploidModeSelection {
        guard let key = haploidModeDefaultsKey(bundleIdentifier: bundleIdentifier),
              let raw = UserDefaults.standard.string(forKey: key),
              let value = HaploidModeSelection(rawValue: raw) else {
            return .auto
        }
        return value
    }

    func saveHaploidModeSelection(_ selection: HaploidModeSelection, bundleIdentifier: String?) {
        guard let key = haploidModeDefaultsKey(bundleIdentifier: bundleIdentifier) else { return }
        UserDefaults.standard.set(selection.rawValue, forKey: key)
    }

    func applyHaploidModeSelectionToIndex() {
        guard let index = searchIndex else { return }
        switch haploidModeSelection {
        case .auto:
            index.setHaploidOverride(nil)
        case .haploid:
            index.setHaploidOverride(true)
        case .diploid:
            index.setHaploidOverride(false)
        }
        currentSampleDisplayState.useHaploidAFShading = index.isLikelyHaploidOrganism
    }

    func rebuildHaploidModeMenu() {
        haploidModeButton.removeAllItems()
        haploidModeButton.addItems(withTitles: ["Auto", "Haploid", "Diploid"])
        haploidModeButton.lastItem?.isEnabled = true
        haploidModeButton.item(at: 0)?.tag = 0
        haploidModeButton.item(at: 1)?.tag = 1
        haploidModeButton.item(at: 2)?.tag = 2
        switch haploidModeSelection {
        case .auto:
            haploidModeButton.selectItem(at: 0)
        case .haploid:
            haploidModeButton.selectItem(at: 1)
        case .diploid:
            haploidModeButton.selectItem(at: 2)
        }
    }

    /// Switches to the specified tab, reconfiguring columns, chip bar, and data.
    func switchToTab(_ tab: DrawerTab) {
        guard tab != activeTab || (tab == .samples ? displayedSamples.isEmpty : displayedAnnotations.isEmpty) else { return }
        viewportSyncWorkItem?.cancel()
        viewportSyncWorkItem = nil
        if tab != .variants {
            invalidateInFlightVariantQueries()
            hideVariantQueryProgress()
        }
        activeTab = tab
        tabControl.selectedSegment = tab.rawValue
        updateSearchFieldVisibility()

        // Multi-select for annotations, variants, and samples tabs.
        tableView.allowsMultipleSelection = true

        switch tab {
        case .annotations:
            annotationFilterField.stringValue = annotationFilterText
        case .variants:
            break  // Query Builder manages variantFilterText directly
        case .samples:
            sampleFilterField.stringValue = sampleFilterText
        }

        // Reset variant subtab when switching to variants
        if tab == .variants {
            activeVariantSubtab = .calls
            variantSubtabControl.selectedSegment = 0
        }

        // Reconfigure columns for the new tab
        configureColumnsForTab(tab)

        // Rebuild chip buttons for the new tab's types (hidden for samples)
        rebuildChipButtons()

        // Re-query for the new tab's data
        if tab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }

        // Keep viewport-synced variants fresh when the user switches to that tab.
        if tab == .variants {
            markVariantFilterStateMutated()
            handleCoordinateSyncFromViewer()
        }
    }

    // MARK: - Data Loading

    /// Connects the drawer to a search index for direct SQL queries.
    /// Does NOT load all annotations into memory — queries the database on demand.
    func setSearchIndex(_ index: AnnotationSearchIndex) {
        searchIndex = index
        isLoading = false
        cachedGlobalFilteredVariantRows = []
        cachedGlobalFilteredVariantKey = nil
        markVariantFilterStateMutated()
        viewportRegionAtLastFilterMutation = nil

        // Get metadata from the index — track annotation and variant counts separately
        totalAnnotationCount = index.entryCount
        totalVariantCount = index.variantCount
        availableAnnotationTypes = index.annotationTypes
        availableVariantTypes = index.variantTypes

        // Discover INFO field definitions for dynamic variant columns
        infoColumnKeys = index.variantInfoKeys.map { (key: $0.key, type: $0.type, description: $0.description) }
        annotationAttributeColumnKeys = Self.orderedAnnotationAttributeKeys(
            from: index.queryAnnotationsOnly(limit: Self.maxDisplayCount)
        )
        let previousTrackDisplayState = annotationTrackDisplayState
        for handle in index.annotationDatabaseHandles {
            if let name = index.annotationTrackName(for: handle.trackId) {
                annotationTrackDisplayNames[handle.trackId] = name
            }
        }
        syncAnnotationTracks(from: index.annotationDatabaseHandles.map(\.trackId))
        if annotationTrackDisplayState != previousTrackDisplayState {
            emitAnnotationTrackDisplayStateIfNeeded()
        }
        variantTrackDatabaseURLs = index.variantDatabaseHandles.map(\.db.databaseURL)
        variantInfoPresetValues = []
        variantPresetLoadState = .idle
        selectedVariantPresetByKey.removeAll()

        // Apply persisted haploid-mode override (if present), then compute availability.
        haploidModeSelection = loadHaploidModeSelection(bundleIdentifier: index.bundleIdentifier)
        applyHaploidModeSelectionToIndex()
        isHaploidOrganism = index.isLikelyHaploidOrganism
        rebuildHaploidModeMenu()

        // All types visible by default for both tabs
        visibleAnnotationTypes = Set(availableAnnotationTypes)
        visibleVariantTypes = Set(availableVariantTypes)

        // Populate sample data from variant databases
        populateSampleData(from: index)

        // Load bookmarked variant IDs for star column display
        loadBookmarkedVariantIds()

        // Enable/disable variant tab based on whether variants exist
        tabControl.setEnabled(totalVariantCount > 0, forSegment: 1)
        // Enable/disable samples tab based on whether samples exist
        tabControl.setEnabled(!allSampleNames.isEmpty, forSegment: 2)
        // Show the tab control only when we have at least one type of data
        tabControl.isHidden = totalVariantCount == 0 && allSampleNames.isEmpty

        // Reconfigure columns if we're already on the variants tab so INFO columns appear
        if activeTab == .annotations {
            configureColumnsForTab(.annotations)
        } else if activeTab == .variants {
            configureColumnsForTab(.variants)
        } else if activeTab == .samples {
            configureColumnsForTab(.samples)
        }

        // Load pre-built SmartToken cache state (counts from persistent tables, instant).
        loadSmartTokenCounts(from: index)
        enforceMaterializedOnlyRestrictionsIfNeeded()

        // Rebuild chip buttons for the active tab
        rebuildChipButtons()
        updateSearchFieldVisibility()

        // Query for initial display
        if activeTab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }
        annotationDrawerLogger.info("AnnotationTableDrawerView: Connected to index with \(self.totalAnnotationCount) annotations, \(self.totalVariantCount) variants, \(self.allSampleNames.count) samples")
    }

    /// Reads pre-built token cache counts from variant databases (instant — no table scans).
    ///
    /// Token tables are built during import and persisted in the database file.
    /// This just reads their row counts to populate chip labels.
    func loadSmartTokenCounts(from index: AnnotationSearchIndex) {
        let handles = index.variantDatabaseHandles
        guard !handles.isEmpty else {
            smartTokenCounts = [:]
            materializedTokenNamesAcrossTracks = []
            return
        }

        var aggregatedCounts: [String: Int] = [:]
        var intersection: Set<String>?
        for handle in handles {
            let state = handle.db.tokenCacheState
            let readyNames = Set(state.compactMap { key, value in value.ready ? key : nil })
            if let existing = intersection {
                intersection = existing.intersection(readyNames)
            } else {
                intersection = readyNames
            }
            for (key, value) in state where value.ready {
                aggregatedCounts[key, default: 0] += value.count
            }
        }
        smartTokenCounts = aggregatedCounts
        materializedTokenNamesAcrossTracks = intersection ?? []
        rebuildChipButtons()
    }

    /// Legacy entry point for when no search index is available (fallback).
    func setAnnotations(_ results: [AnnotationSearchIndex.SearchResult]) {
        searchIndex = nil
        isLoading = false
        totalAnnotationCount = results.count

        let typeSet = Set(results.map { $0.type })
        availableAnnotationTypes = typeSet.sorted()
        visibleAnnotationTypes = typeSet
        annotationAttributeColumnKeys = Self.orderedAnnotationAttributeKeys(from: results)
        let previousTrackDisplayState = annotationTrackDisplayState
        for result in results {
            if let trackName = result.trackName, !trackName.isEmpty {
                annotationTrackDisplayNames[result.trackId] = trackName
            }
        }
        syncAnnotationTracks(from: results.map(\.trackId))
        if annotationTrackDisplayState != previousTrackDisplayState {
            emitAnnotationTrackDisplayStateIfNeeded()
        }
        configureColumnsForTab(.annotations)

        rebuildChipButtons()

        // For legacy mode, set results directly (capped at maxDisplayCount)
        if results.count > Self.maxDisplayCount {
            setAnnotationBaseResults([])
            tableView.reloadData()
            scrollView.isHidden = false
            let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
            let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
            tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
            tooManyLabel.isHidden = false
        } else {
            setAnnotationBaseResults(results)
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
        }
        updateCountLabel()
        annotationDrawerLogger.info("AnnotationTableDrawerView: Loaded \(results.count) annotations (legacy mode)")
    }

    // MARK: - Chip Management

    func rebuildChipButtons() {
        // Remove existing chip buttons
        for view in chipStackView.arrangedSubviews {
            chipStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chipButtons.removeAll()
        variantPresetChipButtons.removeAll()
        variantPresetChipPayloads.removeAll()
        variantPresetMorePayloads.removeAll()
        smartTokenButtons.removeAll()
        smartTokenPayloads.removeAll()
        sampleTokenButtons.removeAll()
        sampleTokenPayloads.removeAll()

        var hasSmartTokens = false
        let isMaterializedOnlyDatabase = isMaterializedOnlyModeEnabled()
        // Smart tokens for the variants tab (grouped by semantic section).
        if activeTab == .variants {
            let infoKeySet = Set(infoColumnKeys.map(\.key))
            let variantTypeSet = Set(availableVariantTypes)
            let hasGT = !allSampleNames.isEmpty
            for section in SmartToken.UISection.allCases {
                let sectionTokens = SmartToken.allCases.filter { $0.uiSection == section }
                // Only show section if at least one token is available
                let anyAvailable = sectionTokens.contains {
                    $0.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                }
                guard anyAvailable else { continue }
                if hasSmartTokens {
                    let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 1))
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
                    chipStackView.addArrangedSubview(spacer)
                }
                let label = NSTextField(labelWithString: section.title)
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                chipStackView.addArrangedSubview(label)
                for token in sectionTokens {
                    let isTokenAvailable = token.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                    let isTokenMaterialized = isMaterializedTokenAllowedInStrictMode(token)
                    let chip = makeSmartTokenChipButton(token: token)
                    if !isTokenAvailable || !isTokenMaterialized {
                        chip.isEnabled = false
                        chip.alphaValue = 0.4
                        if !isTokenMaterialized, isMaterializedOnlyDatabase {
                            chip.toolTip = "Disabled for very large variant databases (token is not pre-materialized)."
                        } else {
                            chip.toolTip = token.unavailabilityReason(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                        }
                    }
                    chipStackView.addArrangedSubview(chip)
                    smartTokenButtons[token] = chip
                    smartTokenPayloads[ObjectIdentifier(chip)] = token
                }
                hasSmartTokens = true
            }
            if hasSmartTokens && !availableTypes.isEmpty {
                let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 1))
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
                chipStackView.addArrangedSubview(spacer)
            }
        }

        if activeTab == .samples {
            let sampleTokens = SampleSmartToken.allCases
            let label = NSTextField(labelWithString: "Sample Filters")
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            chipStackView.addArrangedSubview(label)
            for token in sampleTokens {
                let chip = NSButton(title: token.label, target: self, action: #selector(sampleTokenToggled(_:)))
                chip.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                chip.controlSize = NSControl.ControlSize.small
                chip.bezelStyle = token.exclusivityGroupKey == nil ? NSButton.BezelStyle.recessed : NSButton.BezelStyle.rounded
                chip.isBordered = true
                chip.setButtonType(NSButton.ButtonType.pushOnPushOff)
                chip.state = activeSampleTokens.contains(token) ? NSControl.StateValue.on : NSControl.StateValue.off
                chip.translatesAutoresizingMaskIntoConstraints = false
                chipStackView.addArrangedSubview(chip)
                sampleTokenButtons[token] = chip
                sampleTokenPayloads[ObjectIdentifier(chip)] = token
            }
            hasSmartTokens = !sampleTokenButtons.isEmpty
        }

        // Create a chip for each type
        for type in availableTypes {
            let chip = makeTypeChipButton(type: type)
            chip.state = visibleTypes.contains(type) ? .on : .off
            chipStackView.addArrangedSubview(chip)
            chipButtons[type] = chip
        }

        if activeTab == .variants, showVariantPresetChips, !variantInfoPresetValues.isEmpty, !isMaterializedOnlyDatabase {
            let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 1))
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 12).isActive = true
            chipStackView.addArrangedSubview(spacer)

            for preset in variantInfoPresetValues {
                if preset.values.isEmpty { continue }
                let label = NSTextField(labelWithString: "\(preset.key):")
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .secondaryLabelColor
                chipStackView.addArrangedSubview(label)

                let shownValues = Array(preset.values.prefix(8))
                for value in shownValues {
                    let token = "\(preset.key)\t\(value)"
                    let chip = NSButton(title: value, target: self, action: #selector(variantPresetChipToggled(_:)))
                    chip.font = .systemFont(ofSize: 10, weight: .medium)
                    chip.controlSize = .small
                    chip.bezelStyle = .recessed
                    chip.isBordered = true
                    chip.setButtonType(.pushOnPushOff)
                    chip.state = (selectedVariantPresetByKey[preset.key] == value) ? .on : .off
                    chip.translatesAutoresizingMaskIntoConstraints = false
                    chipStackView.addArrangedSubview(chip)
                    variantPresetChipButtons[token] = chip
                    variantPresetChipPayloads[ObjectIdentifier(chip)] = (key: preset.key, value: value)
                }
                if preset.values.count > shownValues.count {
                    let moreButton = NSButton(title: "More...", target: self, action: #selector(showVariantPresetMoreValues(_:)))
                    moreButton.font = .systemFont(ofSize: 10, weight: .regular)
                    moreButton.controlSize = .small
                    moreButton.bezelStyle = .recessed
                    moreButton.translatesAutoresizingMaskIntoConstraints = false
                    chipStackView.addArrangedSubview(moreButton)
                    variantPresetMorePayloads[ObjectIdentifier(moreButton)] = preset.key
                }
            }
        }

        // Show chip bar if we have types or smart tokens (never for samples tab)
        let hasPresetUI = activeTab == .variants && showVariantPresetChips && (!variantPresetChipButtons.isEmpty || !variantPresetMorePayloads.isEmpty)
        if activeTab == .samples {
            chipBar.isHidden = !hasSmartTokens
            updateSampleFilterIndicator()
        } else {
            chipBar.isHidden = availableTypes.isEmpty && !hasPresetUI && !hasSmartTokens
        }
        updateVariantLogicSummary()
    }

    func updateChipStates() {
        for (type, button) in chipButtons {
            button.state = visibleTypes.contains(type) ? .on : .off
        }
        for (token, button) in variantPresetChipButtons {
            let parts = token.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            button.state = selectedVariantPresetByKey[parts[0]] == parts[1] ? .on : .off
        }
        for (token, button) in smartTokenButtons {
            button.state = activeSmartTokens.contains(token) ? .on : .off
        }
        for (token, button) in sampleTokenButtons {
            button.state = activeSampleTokens.contains(token) ? .on : .off
        }
        updateVariantLogicSummary()
        updateSampleFilterIndicator()
    }

    @objc func smartTokenToggled(_ sender: NSButton) {
        guard let token = smartTokenPayloads[ObjectIdentifier(sender)] else { return }
        guard isMaterializedTokenAllowedInStrictMode(token) else {
            sender.state = .off
            return
        }
        if sender.state == .on {
            if let group = token.exclusivityGroupKey {
                for existing in activeSmartTokens where existing != token && existing.exclusivityGroupKey == group {
                    activeSmartTokens.remove(existing)
                }
            }
            activeSmartTokens.insert(token)
        } else {
            activeSmartTokens.remove(token)
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateVariantFilterIndicator()
        updateDisplayedAnnotations()
    }

    @objc func variantPresetChipToggled(_ sender: NSButton) {
        guard let payload = variantPresetChipPayloads[ObjectIdentifier(sender)] else { return }
        let key = payload.key
        let value = payload.value
        if sender.state == .on {
            selectedVariantPresetByKey[key] = value
        } else {
            selectedVariantPresetByKey.removeValue(forKey: key)
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateVariantFilterIndicator()
        updateDisplayedAnnotations()
    }

    @objc func toggleVariantPresetChips(_ sender: NSButton) {
        loadVariantPresetValuesIfNeeded()
        showVariantPresetChips.toggle()
        presetFiltersToggleButton.title = showVariantPresetChips ? "Presets ▾" : "Presets ▸"
        rebuildChipButtons()
    }

    @objc func showVariantPresetMoreValues(_ sender: NSButton) {
        guard let key = variantPresetMorePayloads[ObjectIdentifier(sender)],
              let preset = variantInfoPresetValues.first(where: { $0.key == key }) else { return }
        let menu = NSMenu(title: "\(key) values")
        let clearItem = NSMenuItem(title: "(Any)", action: #selector(selectVariantPresetValue(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.representedObject = ["key": key, "value": ""]
        menu.addItem(clearItem)
        menu.addItem(.separator())
        for value in preset.values {
            let item = NSMenuItem(title: value, action: #selector(selectVariantPresetValue(_:)), keyEquivalent: "")
            item.target = self
            item.state = (selectedVariantPresetByKey[key] == value) ? .on : .off
            item.representedObject = ["key": key, "value": value]
            menu.addItem(item)
        }
        let point = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc func selectVariantPresetValue(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let value = payload["value"] else { return }
        if value.isEmpty {
            selectedVariantPresetByKey.removeValue(forKey: key)
        } else {
            selectedVariantPresetByKey[key] = value
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateDisplayedAnnotations()
    }

}
