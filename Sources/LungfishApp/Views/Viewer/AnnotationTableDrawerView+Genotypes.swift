// AnnotationTableDrawerView+Genotypes.swift - Genotype subtab within Variants tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

extension ThemeColor {
    /// Converts a ThemeColor to NSColor for use in AppKit table cells.
    var nsColor: NSColor {
        NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

private let genotypeLogger = Logger(subsystem: "com.lungfish.app", category: "GenotypeTab")

// MARK: - Variant Subtab

extension AnnotationTableDrawerView {

    /// Subtab within the Variants tab.
    enum VariantSubtab: Int {
        case calls = 0
        case genotypes = 1
    }

    // MARK: - Genotype Display Row

    /// A single row in the genotype subtab display.
    struct GenotypeDisplayRow: Sendable {
        let sampleName: String
        let variantRowId: Int64
        let variantID: String   // rs ID or "."
        let chromosome: String
        let position: Int       // 0-based
        let ref: String
        let alt: String
        let genotype: String    // Raw GT string (e.g. "0/1")
        let zygosity: String    // "Het", "Hom Ref", "Hom Alt", "Missing"
        let alleleDepths: String // AD field
        let depth: Int?         // DP
        let genotypeQuality: Int? // GQ
        let alleleBalance: Double? // Computed from AD
        let infoDict: [String: String] // INFO key-value pairs for this variant

        /// Classifies genotype for display.
        static func classify(allele1: Int, allele2: Int) -> String {
            if allele1 < 0 || allele2 < 0 { return "Missing" }
            if allele1 == 0 && allele2 == 0 { return "Hom Ref" }
            if allele1 == allele2 { return "Hom Alt" }
            return "Het"
        }

        /// Computes allele balance from AD string (e.g. "10,15" -> 0.6).
        static func computeAlleleBalance(from adString: String?) -> Double? {
            guard let adString, !adString.isEmpty else { return nil }
            let parts = adString.split(separator: ",").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            let total = parts.reduce(0, +)
            guard total > 0 else { return nil }
            // Allele balance = alt reads / total reads
            let altReads = parts.dropFirst().reduce(0, +)
            return Double(altReads) / Double(total)
        }
    }

    // MARK: - Genotype Column Identifiers

    static let gtSampleColumn = NSUserInterfaceItemIdentifier("GTSampleColumn")
    static let gtVariantColumn = NSUserInterfaceItemIdentifier("GTVariantColumn")
    static let gtChromColumn = NSUserInterfaceItemIdentifier("GTChromColumn")
    static let gtPositionColumn = NSUserInterfaceItemIdentifier("GTPosColumn")
    static let gtGenotypeColumn = NSUserInterfaceItemIdentifier("GTGenotypeColumn")
    static let gtZygosityColumn = NSUserInterfaceItemIdentifier("GTZygosityColumn")
    static let gtADColumn = NSUserInterfaceItemIdentifier("GTADColumn")
    static let gtDPColumn = NSUserInterfaceItemIdentifier("GTDPColumn")
    static let gtGQColumn = NSUserInterfaceItemIdentifier("GTGQColumn")
    static let gtABColumn = NSUserInterfaceItemIdentifier("GTABColumn")

    /// Column definitions for the genotype subtab.
    static let genotypeColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (gtSampleColumn, "Sample", 120, 60, "sample"),
        (gtVariantColumn, "Variant", 120, 60, "variant"),
        (gtChromColumn, "Chrom", 100, 50, "chromosome"),
        (gtPositionColumn, "Position", 90, 60, "position"),
        (gtGenotypeColumn, "GT", 60, 40, "genotype"),
        (gtZygosityColumn, "Zygosity", 80, 50, "zygosity"),
        (gtADColumn, "AD", 80, 40, "ad"),
        (gtDPColumn, "DP", 50, 30, "dp"),
        (gtGQColumn, "GQ", 50, 30, "gq"),
        (gtABColumn, "Allele Bal.", 80, 50, "ab"),
    ]

    // MARK: - Configure Genotype Columns

    /// Configures table columns for the genotype subtab.
    func configureColumnsForGenotypes() {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }

        for (identifier, title, width, minWidth, sortKey) in Self.genotypeColumnDefs {
            let col = NSTableColumn(identifier: identifier)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.resizingMask = .autoresizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: sortKey, ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
            tableView.addTableColumn(col)
        }

        // Add dynamic INFO columns (same promoted ordering as Calls tab)
        let promotedKeys = Self.promotedInfoKeys(from: infoColumnKeys)
        let promotedKeySet = Set(promotedKeys.map { $0.key })
        for info in promotedKeys {
            addGenotypeInfoColumn(info)
        }
        for info in infoColumnKeys where !promotedKeySet.contains(info.key) {
            addGenotypeInfoColumn(info)
        }

        // Apply saved column preferences for genotype tab
        if let saved = ColumnPrefsKey.load(tab: "variantGenotypes") {
            let hiddenIds = Set(saved.columns.filter { !$0.isVisible }.map(\.id))
            for col in tableView.tableColumns.reversed() {
                if hiddenIds.contains(col.identifier.rawValue) {
                    tableView.removeTableColumn(col)
                }
            }
            let orderedIds = saved.visibleColumns.map(\.id)
            for (targetIndex, colId) in orderedIds.enumerated() {
                if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colId }),
                   currentIndex != targetIndex, targetIndex < tableView.tableColumns.count {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }
    }

    /// Adds a single INFO column to the genotype subtab.
    private func addGenotypeInfoColumn(_ info: (key: String, type: String, description: String)) {
        let identifier = NSUserInterfaceItemIdentifier("gtinfo_\(info.key)")
        let col = NSTableColumn(identifier: identifier)
        col.title = info.key
        col.headerToolTip = info.description.isEmpty ? info.key : "\(info.description) (\(info.key))"
        col.width = max(80, CGFloat(info.key.count + 2) * 7)
        col.minWidth = 40
        col.resizingMask = .autoresizingMask
        col.sortDescriptorPrototype = NSSortDescriptor(
            key: "gtinfo_\(info.key)", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        tableView.addTableColumn(col)
    }

    // MARK: - Build Genotype Rows

    /// Batch-fetches genotypes for the currently displayed variant rows.
    /// Runs database queries on a background queue.
    func buildGenotypeRows() {
        let variants = displayedAnnotations
        guard !variants.isEmpty else {
            displayedGenotypes = []
            tableView.reloadData()
            updateCountLabel()
            return
        }

        genotypeFetchGeneration += 1
        let thisGeneration = genotypeFetchGeneration
        let handlesByTrack = Dictionary(
            uniqueKeysWithValues: (searchIndex?.variantDatabaseHandles ?? []).map { ($0.trackId, $0.db) }
        )
        let hiddenSamples = currentSampleDisplayState.hiddenSamples

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var rows: [GenotypeDisplayRow] = []

            let variantsByTrack = Dictionary(grouping: variants, by: \.trackId)
            for (trackId, trackVariants) in variantsByTrack {
                guard let db = handlesByTrack[trackId] else { continue }
                let variantIds = trackVariants.compactMap(\.variantRowId)
                guard !variantIds.isEmpty else { continue }
                let genotypesByVariant = db.genotypes(forVariantIds: variantIds)
                let infoByVariant = db.batchInfoValues(variantIds: variantIds)
                let variantPairs: [(Int64, AnnotationSearchIndex.SearchResult)] = trackVariants.compactMap { variant in
                    guard let rowId = variant.variantRowId else { return nil }
                    return (rowId, variant)
                }
                let variantById = Dictionary(uniqueKeysWithValues: variantPairs)

                for variantId in variantIds {
                    guard let variant = variantById[variantId] else { continue }
                    let info = infoByVariant[variantId] ?? [:]
                    for gt in genotypesByVariant[variantId] ?? [] {
                        // Skip hidden samples
                        if hiddenSamples.contains(gt.sampleName) { continue }

                        let zygosity = GenotypeDisplayRow.classify(allele1: gt.allele1, allele2: gt.allele2)
                        let ab = GenotypeDisplayRow.computeAlleleBalance(from: gt.alleleDepths)

                        rows.append(GenotypeDisplayRow(
                            sampleName: gt.sampleName,
                            variantRowId: variantId,
                            variantID: variant.name,
                            chromosome: variant.chromosome,
                            position: variant.start,
                            ref: variant.ref ?? "",
                            alt: variant.alt ?? "",
                            genotype: gt.genotype ?? "./.",
                            zygosity: zygosity,
                            alleleDepths: gt.alleleDepths ?? "",
                            depth: gt.depth,
                            genotypeQuality: gt.genotypeQuality,
                            alleleBalance: ab,
                            infoDict: info
                        ))
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.genotypeFetchGeneration == thisGeneration else { return }
                    self.baseDisplayedGenotypes = rows
                    self.displayedGenotypes = self.filterGenotypeRows(rows)
                    self.tableView.reloadData()
                    self.updateCountLabel()
                }
            }
        }
    }

    /// Filters genotype rows by the active variant filter text and column filter clauses.
    func filterGenotypeRows(_ rows: [GenotypeDisplayRow]) -> [GenotypeDisplayRow] {
        var result = rows

        // Apply text filter
        let filter = variantFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !filter.isEmpty {
            result = result.filter { row in
                row.sampleName.localizedCaseInsensitiveContains(filter)
                    || row.zygosity.localizedCaseInsensitiveContains(filter)
                    || row.genotype.localizedCaseInsensitiveContains(filter)
                    || row.variantID.localizedCaseInsensitiveContains(filter)
                    || row.chromosome.localizedCaseInsensitiveContains(filter)
            }
        }

        // Apply column filter clauses
        if !genotypeColumnFilterClauses.isEmpty {
            result = result.filter { row in
                genotypeColumnFilterClauses.allSatisfy { clause in
                    let actual = genotypeColumnValue(row, key: clause.key)
                    return genotypeColumnMatches(actual: actual, op: clause.op, expected: clause.value, key: clause.key)
                }
            }
        }

        return result
    }

    // MARK: - Genotype Column Filter Support

    /// Returns the filter key for a genotype column identifier.
    func genotypeFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.gtSampleColumn.rawValue: return "sample"
        case Self.gtVariantColumn.rawValue: return "variant"
        case Self.gtChromColumn.rawValue: return "chromosome"
        case Self.gtPositionColumn.rawValue: return "position"
        case Self.gtGenotypeColumn.rawValue: return "genotype"
        case Self.gtZygosityColumn.rawValue: return "zygosity"
        case Self.gtADColumn.rawValue: return "ad"
        case Self.gtDPColumn.rawValue: return "dp"
        case Self.gtGQColumn.rawValue: return "gq"
        case Self.gtABColumn.rawValue: return "ab"
        default:
            if columnId.hasPrefix("gtinfo_") { return columnId }
            return nil
        }
    }

    /// Returns true if the genotype column key is numeric.
    func isGenotypeFilterNumericKey(_ key: String) -> Bool {
        switch key {
        case "position", "dp", "gq", "ab":
            return true
        default:
            if key.hasPrefix("gtinfo_") {
                let infoKey = String(key.dropFirst(7))
                return isNumericInfoKey(infoKey)
            }
            return false
        }
    }

    /// Extracts the display value for a genotype row by filter key.
    private func genotypeColumnValue(_ row: GenotypeDisplayRow, key: String) -> String {
        switch key {
        case "sample": return row.sampleName
        case "variant": return row.variantID
        case "chromosome": return row.chromosome
        case "position": return String(row.position + 1)
        case "genotype": return row.genotype
        case "zygosity": return row.zygosity
        case "ad": return row.alleleDepths
        case "dp": return row.depth.map(String.init) ?? ""
        case "gq": return row.genotypeQuality.map(String.init) ?? ""
        case "ab": return row.alleleBalance.map { String(format: "%.2f", $0) } ?? ""
        default:
            if key.hasPrefix("gtinfo_") {
                let infoKey = String(key.dropFirst(7))
                return row.infoDict[infoKey] ?? ""
            }
            return ""
        }
    }

    /// Checks if an actual value matches a filter clause.
    private func genotypeColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
        let normActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNumericOp = op == ">" || op == ">=" || op == "<" || op == "<="
        let isKnownNumeric = key == "position" || key == "dp" || key == "gq" || key == "ab"
        if (isKnownNumeric || (isNumericOp && key.hasPrefix("gtinfo_"))),
           let lhs = Double(normActual), let rhs = Double(normExpected) {
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
        return sampleStringMatches(actual: normActual, op: op, expected: normExpected)
    }

    /// Reapplies genotype column filters, syncs variant display, and refreshes the table.
    func applyGenotypeColumnFiltersFromBase() {
        displayedGenotypes = filterGenotypeRows(baseDisplayedGenotypes)

        // Sync displayedAnnotations to only include variants with surviving genotype rows
        if genotypeColumnFilterClauses.isEmpty {
            displayedAnnotations = applyVariantColumnFilters(to: baseDisplayedVariantAnnotations)
        } else {
            let survivingVariantIds = Set(displayedGenotypes.map(\.variantRowId))
            displayedAnnotations = applyVariantColumnFilters(to: baseDisplayedVariantAnnotations).filter { row in
                guard let rowId = row.variantRowId else { return false }
                return survivingVariantIds.contains(rowId)
            }
        }

        tableView.reloadData()
        updateCountLabel()
        emitVisibleVariantRenderKeyUpdateIfNeeded()
    }

    // MARK: - Genotype Cell Value

    /// Returns the display string for a genotype table cell.
    func genotypeCellValueString(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        guard row < displayedGenotypes.count else { return "" }
        let gt = displayedGenotypes[row]

        switch identifier {
        case Self.gtSampleColumn:
            return gt.sampleName
        case Self.gtVariantColumn:
            return gt.variantID
        case Self.gtChromColumn:
            return gt.chromosome
        case Self.gtPositionColumn:
            let displayPos = gt.position + 1
            return numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
        case Self.gtGenotypeColumn:
            return gt.genotype
        case Self.gtZygosityColumn:
            return gt.zygosity
        case Self.gtADColumn:
            return gt.alleleDepths
        case Self.gtDPColumn:
            return gt.depth.map(String.init) ?? "."
        case Self.gtGQColumn:
            return gt.genotypeQuality.map(String.init) ?? "."
        case Self.gtABColumn:
            if let ab = gt.alleleBalance {
                return String(format: "%.2f", ab)
            }
            return "."
        default:
            if identifier.rawValue.hasPrefix("gtinfo_") {
                let key = String(identifier.rawValue.dropFirst(7))
                return gt.infoDict[key] ?? "."
            }
            return ""
        }
    }

    // MARK: - Genotype Cell View

    /// Creates or configures the cell view for a genotype row.
    func genotypeView(for column: NSTableColumn, row: Int) -> NSView {
        let identifier = column.identifier
        let cellId = NSUserInterfaceItemIdentifier("GenotypeCell_\(identifier.rawValue)")
        let cellView: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 11)
            cellView.addSubview(textField)
            cellView.textField = textField
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let text = genotypeCellValueString(for: identifier, row: row)
        cellView.textField?.stringValue = text

        // Right-align numeric columns (position, DP, GQ, AB, numeric INFO)
        let isNumeric = identifier == Self.gtPositionColumn
            || identifier == Self.gtDPColumn
            || identifier == Self.gtGQColumn
            || identifier == Self.gtABColumn
            || (identifier.rawValue.hasPrefix("gtinfo_") && Double(text) != nil)
        cellView.textField?.alignment = isNumeric ? .right : .left

        // Color the GT and Zygosity columns using the active variant color theme
        if (identifier == Self.gtGenotypeColumn || identifier == Self.gtZygosityColumn),
           row < displayedGenotypes.count {
            let gt = displayedGenotypes[row]
            cellView.textField?.textColor = genotypeColor(for: gt.zygosity)
        } else {
            cellView.textField?.textColor = .labelColor
        }

        return cellView
    }

    /// Returns the NSColor for a zygosity string using the active variant color theme.
    private func genotypeColor(for zygosity: String) -> NSColor {
        let theme = VariantColorTheme.named(AppSettings.shared.variantColorThemeName)
        switch zygosity {
        case "Het":     return theme.het.nsColor
        case "Hom Alt": return theme.homAlt.nsColor
        case "Hom Ref": return theme.homRef.nsColor
        default:        return .secondaryLabelColor
        }
    }

    // MARK: - Genotype Column Header Filter Menu

    /// Shows the genotype column header filter menu on column click.
    func showGenotypeColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildGenotypeColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    /// Builds the genotype column header context menu with sort and filter options.
    func buildGenotypeColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        let tableColumn = tableView.tableColumns[column]
        guard let key = genotypeFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else { return }
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title

        // Sort options
        let sortAscItem = NSMenuItem(
            title: "Sort \(displayName) Ascending",
            action: #selector(sortGenotypeColumnAscending(_:)),
            keyEquivalent: ""
        )
        sortAscItem.target = self
        sortAscItem.representedObject = tableColumn
        menu.addItem(sortAscItem)

        let sortDescItem = NSMenuItem(
            title: "Sort \(displayName) Descending",
            action: #selector(sortGenotypeColumnDescending(_:)),
            keyEquivalent: ""
        )
        sortDescItem.target = self
        sortDescItem.representedObject = tableColumn
        menu.addItem(sortDescItem)

        menu.addItem(NSMenuItem.separator())

        // Filter options
        if isGenotypeFilterNumericKey(key) {
            for (label, op) in [
                ("Equals\u{2026}", "="),
                ("\u{2265}\u{2026}", ">="),
                (">\u{2026}", ">"),
                ("\u{2264}\u{2026}", "<="),
                ("<\u{2026}", "<"),
            ] {
                let item = NSMenuItem(
                    title: "Filter \(displayName) \(label)",
                    action: #selector(promptGenotypeColumnFilterAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        } else {
            for (label, op) in [
                ("Contains\u{2026}", "~"),
                ("Equals\u{2026}", "="),
                ("Begins With\u{2026}", "^="),
                ("Ends With\u{2026}", "$="),
            ] {
                let item = NSMenuItem(
                    title: "Filter \(displayName) \(label)",
                    action: #selector(promptGenotypeColumnFilterAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        addGenotypeColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addGenotypeColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")

        if !genotypeColumnFilterClauses.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(
                title: "Clear Genotype Column Filters",
                action: #selector(clearGenotypeColumnFilters(_:)),
                keyEquivalent: ""
            )
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }

    private func addGenotypeColumnFilterItem(to menu: NSMenu, title: String, key: String, op: String, value: String) {
        let item = NSMenuItem(title: title, action: #selector(applyGenotypeColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc private func promptGenotypeColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Genotype Column Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !value.isEmpty else { return }
            self.genotypeColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
            self.applyGenotypeColumnFiltersFromBase()
        }
    }

    @objc private func applyGenotypeColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        genotypeColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
        applyGenotypeColumnFiltersFromBase()
    }

    @objc private func clearGenotypeColumnFilters(_ sender: Any?) {
        genotypeColumnFilterClauses.removeAll()
        applyGenotypeColumnFiltersFromBase()
    }

    @objc private func sortGenotypeColumnAscending(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.sortDescriptorPrototype.map { tableView.sortDescriptors = [NSSortDescriptor(key: $0.key, ascending: true, selector: $0.selector)] }
    }

    @objc private func sortGenotypeColumnDescending(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.sortDescriptorPrototype.map { tableView.sortDescriptors = [NSSortDescriptor(key: $0.key, ascending: false, selector: $0.selector)] }
    }
}
