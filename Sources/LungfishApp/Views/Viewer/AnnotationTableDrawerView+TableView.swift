// AnnotationTableDrawerView+TableView.swift - Extracted from AnnotationTableDrawerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import os.log

extension AnnotationTableDrawerView {

    // MARK: - Filter Profiles

    /// Rebuilds the filter profile popup menu.
    func rebuildProfileMenu() {
        profileButton.removeAllItems()
        // Title item (pullsDown mode uses the first item as title)
        profileButton.addItem(withTitle: "Profiles")
        profileButton.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)

        // "None" option to clear profile
        let noneItem = NSMenuItem(title: "No Profile", action: #selector(clearFilterProfile(_:)), keyEquivalent: "")
        noneItem.target = self
        profileButton.menu?.addItem(noneItem)

        profileButton.menu?.addItem(NSMenuItem.separator())

        // Built-in profiles
        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let variantTypeSet = Set(availableVariantTypes)
        let hasGT = !allSampleNames.isEmpty
        for profile in FilterProfile.builtInProfiles {
            // Only show profiles whose tokens are available
            let tokens = profile.smartTokens
            let available = tokens.allSatisfy { $0.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism) }
            guard available || tokens.isEmpty else { continue }
            let item = NSMenuItem(title: profile.name, action: #selector(selectFilterProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            profileButton.menu?.addItem(item)
        }

        // Custom profiles
        let customProfiles = FilterProfileStore.loadCustomProfiles(bundleIdentifier: searchIndex?.bundleIdentifier)
        if !customProfiles.isEmpty {
            profileButton.menu?.addItem(NSMenuItem.separator())
            for profile in customProfiles {
                let item = NSMenuItem(title: profile.name, action: #selector(selectFilterProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile
                profileButton.menu?.addItem(item)
            }
        }

        // Save current as profile
        profileButton.menu?.addItem(NSMenuItem.separator())
        let saveItem = NSMenuItem(title: "Save Current as Profile\u{2026}", action: #selector(saveCurrentAsProfile(_:)), keyEquivalent: "")
        saveItem.target = self
        profileButton.menu?.addItem(saveItem)
    }

    @objc func selectFilterProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? FilterProfile else { return }
        applyFilterProfile(profile)
    }

    @objc func clearFilterProfile(_ sender: Any?) {
        activeSmartTokens.removeAll()
        selectedVariantPresetByKey.removeAll()
        variantFilterText = ""
        markVariantFilterStateMutated()
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    func applyFilterProfile(_ profile: FilterProfile) {
        // Apply smart tokens
        activeSmartTokens = profile.smartTokens.filter { isMaterializedTokenAllowedInStrictMode($0) }

        // Apply filter text
        variantFilterText = isMaterializedOnlyModeEnabled() ? "" : profile.filterText
        if isMaterializedOnlyModeEnabled() {
            selectedVariantPresetByKey.removeAll()
        }
        markVariantFilterStateMutated()

        // Update UI
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    @objc func saveCurrentAsProfile(_ sender: Any?) {
        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Filter Profile"
        alert.informativeText = "Enter a name for this filter profile."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        nameField.placeholderString = "Profile name"
        alert.accessoryView = nameField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }

            let tokens = self.activeSmartTokens.map(\.rawValue)
            let profile = FilterProfile(name: name, activeTokens: tokens, filterText: self.variantFilterText)
            var customs = FilterProfileStore.loadCustomProfiles(bundleIdentifier: self.searchIndex?.bundleIdentifier)
            customs.append(profile)
            FilterProfileStore.saveCustomProfiles(customs, bundleIdentifier: self.searchIndex?.bundleIdentifier)
            self.rebuildProfileMenu()
        }
    }

    func applySampleBuilderSettings(showSamplesText: String, orderText: String) {
        let shownSamples = showSamplesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !shownSamples.isEmpty {
            let shownSet = Set(shownSamples)
            currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !shownSet.contains($0) })
            hasSampleDisplayStateSeed = true
            postSampleDisplayStateChange()
        }

        let orderSamples = orderText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !orderSamples.isEmpty {
            let unique = Array(NSOrderedSet(array: orderSamples)) as? [String] ?? orderSamples
            let existing = Set(allSampleNames)
            var order = unique.filter { existing.contains($0) }
            order.append(contentsOf: allSampleNames.filter { !Set(order).contains($0) })
            currentSampleDisplayState.sampleOrder = order
            hasSampleDisplayStateSeed = true
            postSampleDisplayStateChange()
        }
    }

    func normalizedRegionString(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = parseRegion(trimmed) {
            return "\(parsed.chromosome):\(parsed.start)-\(parsed.end)"
        }
        return nil
    }

    func loadVariantPresetValuesIfNeeded() {
        guard variantPresetLoadState == .idle else { return }
        guard !isMaterializedOnlyModeEnabled() else {
            variantInfoPresetValues = []
            selectedVariantPresetByKey.removeAll()
            variantPresetLoadState = .loaded
            return
        }
        guard !infoColumnKeys.isEmpty, !variantTrackDatabaseURLs.isEmpty else {
            variantPresetLoadState = .loaded
            return
        }

        variantPresetLoadState = .loading
        presetFiltersToggleButton.isEnabled = false
        presetFiltersToggleButton.title = "Presets (loading...)"

        let keys = infoColumnKeys.map(\.key)
        let dbURLs = variantTrackDatabaseURLs

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let maxDistinctValues = 20
            let maxKeys = 4
            var presets: [(key: String, values: [String])] = []
            let databases = dbURLs.compactMap { try? VariantDatabase(url: $0) }

            for key in keys {
                var valueSet = Set<String>()
                var exceeded = false
                for db in databases {
                    let values = db.distinctInfoValues(forKey: key, limit: maxDistinctValues + 1)
                    for value in values {
                        valueSet.insert(value)
                        if valueSet.count > maxDistinctValues {
                            exceeded = true
                            break
                        }
                    }
                    if exceeded { break }
                }
                if exceeded || valueSet.isEmpty { continue }
                let sortedValues = valueSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                presets.append((key: key, values: sortedValues))
                if presets.count >= maxKeys { break }
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.variantInfoPresetValues = presets
                    self.selectedVariantPresetByKey = self.selectedVariantPresetByKey.filter { key, value in
                        presets.contains { $0.key == key && $0.values.contains(value) }
                    }
                    self.variantPresetLoadState = .loaded
                    self.presetFiltersToggleButton.isEnabled = true
                    self.presetFiltersToggleButton.title = self.showVariantPresetChips ? "Presets ▾" : "Presets ▸"
                    if self.activeTab == .variants && self.showVariantPresetChips {
                        self.rebuildChipButtons()
                    }
                    self.updateSearchFieldVisibility()
                }
            }
        }
    }

    // MARK: - Actions

    @objc func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        // Samples and genotype subtab don't navigate on double-click
        guard activeTab != .samples else { return }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            // Navigate to the variant's position for the genotype row
            guard row < displayedGenotypes.count else { return }
            let gt = displayedGenotypes[row]
            // Find the corresponding variant in displayedAnnotations to navigate
            if let variant = displayedAnnotations.first(where: { $0.variantRowId == gt.variantRowId }) {
                delegate?.annotationDrawer(self, didSelectAnnotation: variant)
            }
            return
        }
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        annotationDrawerLogger.info("AnnotationTableDrawerView: Double-clicked '\(annotation.name, privacy: .public)' on \(annotation.chromosome, privacy: .public)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if activeTab == .samples { return displayedSamples.count }
        if activeTab == .variants && activeVariantSubtab == .genotypes { return displayedGenotypes.count }
        return displayedAnnotations.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key else { return }

        let ascending = sortDescriptor.ascending

        if activeTab == .samples {
            let sortedAllSamples = sortedSampleNames(key: key, ascending: ascending, names: resolvedSampleOrder())
            // Sync sort to SampleDisplayState so viewer rendering order matches
            let displayField: String
            switch key {
            case "visible": displayField = "visible"
            case "sample_name": displayField = "name"
            case "source_file": displayField = "source"
            default:
                if key.hasPrefix("meta_") {
                    displayField = String(key.dropFirst(5))
                } else {
                    displayField = key
                }
            }
            currentSampleDisplayState.sortFields = [SortField(field: displayField, ascending: ascending)]
            // Persist full-order sort, not just currently filtered rows.
            currentSampleDisplayState.sampleOrder = sortedAllSamples
            postSampleDisplayStateChange()
            updateDisplayedSamples()
            return
        }

        if activeTab == .variants && activeVariantSubtab == .genotypes {
            displayedGenotypes.sort { a, b in
                let result: ComparisonResult
                switch key {
                case "sample": result = a.sampleName.localizedCaseInsensitiveCompare(b.sampleName)
                case "variant": result = a.variantID.localizedCaseInsensitiveCompare(b.variantID)
                case "chromosome": result = a.chromosome.localizedCaseInsensitiveCompare(b.chromosome)
                case "position":
                    result = a.position < b.position ? .orderedAscending : (a.position > b.position ? .orderedDescending : .orderedSame)
                case "genotype": result = a.genotype.localizedCaseInsensitiveCompare(b.genotype)
                case "zygosity": result = a.zygosity.localizedCaseInsensitiveCompare(b.zygosity)
                case "ad": result = a.alleleDepths.localizedCaseInsensitiveCompare(b.alleleDepths)
                case "dp":
                    let aVal = a.depth ?? -1
                    let bVal = b.depth ?? -1
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                case "gq":
                    let aVal = a.genotypeQuality ?? -1
                    let bVal = b.genotypeQuality ?? -1
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                case "ab":
                    let aVal = a.alleleBalance ?? -1.0
                    let bVal = b.alleleBalance ?? -1.0
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                default:
                    if key.hasPrefix("gtinfo_") {
                        let infoKey = String(key.dropFirst(7))
                        let aVal = a.infoDict[infoKey] ?? ""
                        let bVal = b.infoDict[infoKey] ?? ""
                        // Try numeric comparison first
                        if let aNum = Double(aVal), let bNum = Double(bVal) {
                            result = aNum < bNum ? .orderedAscending : (aNum > bNum ? .orderedDescending : .orderedSame)
                        } else {
                            result = aVal.localizedCaseInsensitiveCompare(bVal)
                        }
                    } else {
                        result = .orderedSame
                    }
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            tableView.reloadData()
            return
        }

        displayedAnnotations.sort { a, b in
            let result: ComparisonResult
            switch key {
            // Annotation columns
            case "name", "variant_id":
                result = a.name.localizedCaseInsensitiveCompare(b.name)
            case "track_id":
                result = a.trackId.localizedCaseInsensitiveCompare(b.trackId)
            case "track_name":
                result = annotationTrackName(for: a).localizedCaseInsensitiveCompare(annotationTrackName(for: b))
            case "type", "variant_type":
                result = a.type.localizedCaseInsensitiveCompare(b.type)
            case "chromosome":
                result = a.chromosome.localizedCaseInsensitiveCompare(b.chromosome)
            case "start", "position":
                result = a.start < b.start ? .orderedAscending : (a.start > b.start ? .orderedDescending : .orderedSame)
            case "end":
                result = a.end < b.end ? .orderedAscending : (a.end > b.end ? .orderedDescending : .orderedSame)
            case "size":
                let sizeA = a.end - a.start
                let sizeB = b.end - b.start
                result = sizeA < sizeB ? .orderedAscending : (sizeA > sizeB ? .orderedDescending : .orderedSame)
            case "strand":
                result = a.strand.compare(b.strand)
            // Variant columns
            case "ref":
                result = (a.ref ?? "").localizedCaseInsensitiveCompare(b.ref ?? "")
            case "alt":
                result = (a.alt ?? "").localizedCaseInsensitiveCompare(b.alt ?? "")
            case "quality":
                let qa = a.quality ?? -1
                let qb = b.quality ?? -1
                result = qa < qb ? .orderedAscending : (qa > qb ? .orderedDescending : .orderedSame)
            case "filter":
                result = (a.filter ?? "").localizedCaseInsensitiveCompare(b.filter ?? "")
            case "samples":
                let sa = a.sampleCount ?? 0
                let sb = b.sampleCount ?? 0
                result = sa < sb ? .orderedAscending : (sa > sb ? .orderedDescending : .orderedSame)
            case "source":
                result = (a.sourceFile ?? "").localizedCaseInsensitiveCompare(b.sourceFile ?? "")
            case "consequence":
                result = variantConsequenceText(for: a).localizedCaseInsensitiveCompare(variantConsequenceText(for: b))
            case "aa_change":
                result = variantAAChangeText(for: a).localizedCaseInsensitiveCompare(variantAAChangeText(for: b))
            default:
                if key.hasPrefix("attr_") {
                    let attributeKey = String(key.dropFirst(5))
                    let valA = a.attributes?[attributeKey] ?? ""
                    let valB = b.attributes?[attributeKey] ?? ""
                    if isNumericAnnotationAttributeKey(attributeKey),
                       let numA = Double(valA),
                       let numB = Double(valB) {
                        result = numA < numB ? .orderedAscending : (numA > numB ? .orderedDescending : .orderedSame)
                    } else {
                        result = valA.localizedCaseInsensitiveCompare(valB)
                    }
                } else if key.hasPrefix("info_") {
                    let infoKey = String(key.dropFirst(5))
                    let valA = a.infoDict?[infoKey] ?? ""
                    let valB = b.infoDict?[infoKey] ?? ""
                    if isNumericInfoKey(infoKey) {
                        let numA = Double(valA) ?? -.infinity
                        let numB = Double(valB) ?? -.infinity
                        result = numA < numB ? .orderedAscending : (numA > numB ? .orderedDescending : .orderedSame)
                    } else {
                        result = valA.localizedCaseInsensitiveCompare(valB)
                    }
                } else {
                    result = .orderedSame
                }
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let identifier = column.identifier

        // Bookmark column (star icon) — custom button, not a text cell
        if identifier == Self.bookmarkColumn {
            return bookmarkView(for: row)
        }

        // Samples tab uses its own data source
        if activeTab == .samples {
            return sampleCellView(for: identifier, row: row)
        }

        // Genotype subtab uses its own data source
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            return genotypeView(for: column, row: row)
        }

        guard row < displayedAnnotations.count else { return nil }
        let annotation = displayedAnnotations[row]

        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 11)
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
        tf.alignment = .left  // Reset default alignment
        tf.font = .systemFont(ofSize: 11)  // Reset default font

        switch identifier {
        // Annotation columns
        case Self.nameColumn:
            tf.stringValue = annotation.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case Self.trackNameColumn:
            tf.stringValue = annotationTrackName(for: annotation)
        case Self.trackIdColumn:
            tf.stringValue = annotation.trackId
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case Self.typeColumn:
            tf.stringValue = annotation.type
            tf.font = .systemFont(ofSize: 11)
        case Self.chromosomeColumn:
            tf.stringValue = annotation.chromosome
        case Self.startColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.endColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.sizeColumn:
            let size = annotation.end - annotation.start
            tf.stringValue = formatSize(size)
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.strandColumn:
            tf.stringValue = annotation.strand
            tf.alignment = .center

        // Variant columns
        case Self.variantIdColumn:
            tf.stringValue = annotation.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case Self.variantTypeColumn:
            tf.stringValue = annotation.type
            tf.font = .systemFont(ofSize: 11)
            tf.textColor = variantTypeColor(annotation.type)
        case Self.variantChromColumn:
            tf.stringValue = annotation.chromosome
        case Self.positionColumn:
            // Display as 1-based (VCF convention) — internal storage is 0-based
            let displayPos = annotation.start + 1
            tf.stringValue = numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.refColumn:
            tf.stringValue = annotation.ref ?? ""
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case Self.altColumn:
            tf.stringValue = annotation.alt ?? ""
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case Self.qualityColumn:
            if let q = annotation.quality {
                tf.stringValue = q < 0 ? "." : String(format: "%.1f", q)
            } else {
                tf.stringValue = "."
            }
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.filterColumn:
            tf.stringValue = annotation.filter ?? "."
        case Self.samplesColumn:
            tf.stringValue = "\(annotation.sampleCount ?? 0)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.sourceColumn:
            tf.stringValue = annotation.sourceFile ?? ""
            tf.font = .systemFont(ofSize: 11)
        case Self.consequenceColumn:
            tf.stringValue = variantConsequenceText(for: annotation)
        case Self.aaChangeColumn:
            tf.stringValue = variantAAChangeText(for: annotation)

        default:
            if identifier.rawValue.hasPrefix("attr_") {
                let attributeKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = annotation.attributes?[attributeKey] ?? ""
                tf.alignment = isNumericAnnotationAttributeKey(attributeKey) ? .right : .left
            } else if identifier.rawValue.hasPrefix("info_") {
                let infoKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = annotation.infoDict?[infoKey] ?? ""
                tf.alignment = isNumericInfoKey(infoKey) ? .right : .left
            } else {
                tf.stringValue = ""
            }
        }

        return cellView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingDelegateCallbacks else { return }
        // Samples tab doesn't navigate on selection
        guard activeTab != .samples else { return }
        let selectedRows = tableView.selectedRowIndexes
        // Only navigate to a single selection — multi-select doesn't trigger navigation
        guard selectedRows.count == 1, let row = selectedRows.first else { return }
        // Genotype subtab: navigate to the parent variant
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            guard row < displayedGenotypes.count else { return }
            let gt = displayedGenotypes[row]
            if let variant = displayedAnnotations.first(where: { $0.variantRowId == gt.variantRowId }) {
                delegate?.annotationDrawer(self, didSelectAnnotation: variant)
            }
            return
        }
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        annotationDrawerLogger.debug("AnnotationTableDrawerView: Selected '\(annotation.name, privacy: .public)' at row \(row)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - Formatting

    func formatSize(_ bp: Int) -> String {
        switch bp {
        case 0..<1_000:
            return "\(bp) bp"
        case 1_000..<1_000_000:
            return String(format: "%.1f kb", Double(bp) / 1_000.0)
        default:
            return String(format: "%.1f Mb", Double(bp) / 1_000_000.0)
        }
    }

    func variantConsequenceText(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let info = row.infoDict {
            let candidates = [
                "CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence",
                "ANN_Annotation", "EFFECT", "effect",
            ]
            for key in candidates {
                if let value = normalizedVariantInfoValue(info[key]) {
                    return value
                }
            }
        }
        let fallback = fallbackConsequenceForRow(row).consequence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        if shouldShowDeferredConsequencePlaceholder(for: row) {
            return Self.deferredConsequenceText
        }
        return ""
    }

    func variantAAChangeText(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let info = row.infoDict {
            let candidates = [
                "CSQ_HGVSp", "HGVSp", "ANN_HGVS_p", "AA_CHANGE",
                "CSQ_Amino_acids", "Amino_acids", "ANN_AA_pos_len",
            ]
            for key in candidates {
                if let value = normalizedVariantInfoValue(info[key]) {
                    return value
                }
            }
        }
        let fallback = fallbackConsequenceForRow(row).aaChange?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        if shouldShowDeferredConsequencePlaceholder(for: row) {
            return Self.deferredAAChangeText
        }
        return ""
    }

    func fallbackConsequenceForRow(
        _ row: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?) {
        let key = variantFallbackKey(for: row)
        if let cached = fallbackConsequenceCache[key] {
            return cached
        }
        let resolved = delegate?.annotationDrawer(self, fallbackConsequenceFor: row) ?? (nil, nil)
        let consequence = resolved.0?.trimmingCharacters(in: .whitespacesAndNewlines)
        let aaChange = resolved.1?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (consequence?.isEmpty == false) || (aaChange?.isEmpty == false) {
            fallbackConsequenceCache[key] = (consequence, aaChange)
            return (consequence, aaChange)
        }
        return resolved
    }

    func normalizedVariantInfoValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case ".", "na", "n/a", "null", "none":
            return nil
        default:
            return trimmed
        }
    }

    func shouldShowDeferredConsequencePlaceholder(for row: AnnotationSearchIndex.SearchResult) -> Bool {
        guard row.isVariant, activeTab == .variants else { return false }
        let visibleCount = max(displayedAnnotations.count, lastVariantQueryMatchCount ?? 0)
        return visibleCount > Self.consequenceComputationRowLimit
    }

    func variantFallbackKey(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let rowId = row.variantRowId {
            return "\(row.trackId):\(rowId)"
        }
        let ref = row.ref ?? ""
        let alt = row.alt ?? ""
        return "\(row.trackId):\(row.chromosome):\(row.start):\(ref):\(alt)"
    }

    // MARK: - Column Sizing

    @objc func autoSizeVisibleTableColumns(_ sender: Any?) {
        let columns = tableView.tableColumns
        guard !columns.isEmpty else { return }

        let rowCount = rowCountForAutoSizing()
        let sampledRows = min(rowCount, Self.autoSizeRowSampleLimit)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

        for column in columns {
            autoSize(column: column, sampledRows: sampledRows, bodyFont: bodyFont, headerFont: headerFont)
        }
    }

    @objc func autoSizeSingleColumnFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == identifier }) else { return }

        let rowCount = rowCountForAutoSizing()
        let sampledRows = min(rowCount, Self.autoSizeRowSampleLimit)
        autoSize(
            column: column,
            sampledRows: sampledRows,
            bodyFont: NSFont.systemFont(ofSize: 11),
            headerFont: NSFont.systemFont(ofSize: 11, weight: .semibold)
        )
    }

    func addColumnSizingMenuItems(_ menu: NSMenu, tableColumn: NSTableColumn?) {
        if let tableColumn {
            let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title
            let sizeColumnItem = NSMenuItem(
                title: "Size \(displayName) to Fit",
                action: #selector(autoSizeSingleColumnFromMenu(_:)),
                keyEquivalent: ""
            )
            sizeColumnItem.target = self
            sizeColumnItem.representedObject = tableColumn.identifier.rawValue
            menu.addItem(sizeColumnItem)
        }

        let sizeAllItem = NSMenuItem(
            title: "Size All Columns to Fit",
            action: #selector(autoSizeVisibleTableColumns(_:)),
            keyEquivalent: ""
        )
        sizeAllItem.target = self
        menu.addItem(sizeAllItem)
    }

    func rowCountForAutoSizing() -> Int {
        if activeTab == .samples { return displayedSamples.count }
        if activeTab == .variants && activeVariantSubtab == .genotypes { return displayedGenotypes.count }
        return displayedAnnotations.count
    }

    func autoSize(
        column: NSTableColumn,
        sampledRows: Int,
        bodyFont: NSFont,
        headerFont: NSFont
    ) {
        if column.identifier == Self.bookmarkColumn {
            column.width = 28
            return
        }
        if column.identifier == Self.sampleVisibleColumn {
            column.width = 30
            return
        }

        let headerTitle = column.title.isEmpty ? " " : column.title
        var targetWidth = (headerTitle as NSString).size(withAttributes: [.font: headerFont]).width + 16

        if sampledRows > 0 {
            for row in 0..<sampledRows {
                let text = autoSizeCellValueString(for: column.identifier, row: row)
                guard !text.isEmpty else { continue }
                let width = (text as NSString).size(withAttributes: [.font: bodyFont]).width + 12
                if width > targetWidth { targetWidth = width }
            }
        }

        let clamped = min(max(targetWidth, column.minWidth), 700)
        column.width = ceil(clamped)
    }

    func autoSizeCellValueString(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        if activeTab == .samples {
            guard row < displayedSamples.count else { return "" }
            let sample = displayedSamples[row]
            if identifier == Self.sampleDisplayNameColumn {
                let displayName = sample.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (displayName?.isEmpty == false) ? displayName! : sample.name
            }
            return sampleFilterValue(sample: sample, columnIdentifier: identifier.rawValue)
        }

        if activeTab == .variants && activeVariantSubtab == .genotypes {
            return genotypeCellValueString(for: identifier, row: row)
        }

        guard row < displayedAnnotations.count else { return "" }
        let annotation = displayedAnnotations[row]
        switch identifier {
        case Self.nameColumn, Self.variantIdColumn:
            return annotation.name
        case Self.trackNameColumn:
            return annotationTrackName(for: annotation)
        case Self.trackIdColumn:
            return annotation.trackId
        case Self.typeColumn, Self.variantTypeColumn:
            return annotation.type
        case Self.chromosomeColumn, Self.variantChromColumn:
            return annotation.chromosome
        case Self.startColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
        case Self.endColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
        case Self.sizeColumn:
            return formatSize(annotation.end - annotation.start)
        case Self.strandColumn:
            return annotation.strand
        case Self.positionColumn:
            let displayPos = annotation.start + 1
            return numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
        case Self.refColumn:
            return annotation.ref ?? ""
        case Self.altColumn:
            return annotation.alt ?? ""
        case Self.qualityColumn:
            if let q = annotation.quality {
                return q < 0 ? "." : String(format: "%.1f", q)
            }
            return "."
        case Self.filterColumn:
            return annotation.filter ?? "."
        case Self.samplesColumn:
            return "\(annotation.sampleCount ?? 0)"
        case Self.sourceColumn:
            return annotation.sourceFile ?? ""
        case Self.consequenceColumn:
            return variantConsequenceText(for: annotation)
        case Self.aaChangeColumn:
            return variantAAChangeText(for: annotation)
        default:
            if identifier.rawValue.hasPrefix("attr_") {
                let attributeKey = String(identifier.rawValue.dropFirst(5))
                return annotation.attributes?[attributeKey] ?? ""
            }
            if identifier.rawValue.hasPrefix("info_") {
                let infoKey = String(identifier.rawValue.dropFirst(5))
                return annotation.infoDict?[infoKey] ?? ""
            }
            return ""
        }
    }

    /// Returns the theme-aware NSColor for a variant type string (SNP, INS, DEL, etc.).
    func variantTypeColor(_ type: String) -> NSColor {
        let theme = VariantColorTheme.named(AppSettings.shared.variantColorThemeName)
        switch type {
        case "SNP": return theme.snp.nsColor
        case "INS": return theme.ins.nsColor
        case "DEL": return theme.del.nsColor
        case "MNP": return theme.mnp.nsColor
        default:    return theme.complex.nsColor
        }
    }

    /// Whether an INFO key represents a numeric type (Integer or Float) for sorting.
    func isNumericInfoKey(_ key: String) -> Bool {
        infoColumnKeys.first(where: { $0.key == key }).map { $0.type == "Integer" || $0.type == "Float" } ?? false
    }

    func isNumericAnnotationAttributeKey(_ key: String) -> Bool {
        switch key {
        case "flag", "mapq", "pos_1_based", "alignment_start", "alignment_end",
             "reference_length", "query_length", "mate_position_1_based", "template_length",
             "tag_NM", "tag_AS":
            return true
        default:
            return false
        }
    }

}
