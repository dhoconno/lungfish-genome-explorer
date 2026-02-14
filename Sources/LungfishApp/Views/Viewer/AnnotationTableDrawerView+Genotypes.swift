// AnnotationTableDrawerView+Genotypes.swift - Genotype subtab within Variants tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

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
        let searchIdx = searchIndex

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let searchIdx else { return }
            let handlesByTrack = Dictionary(
                uniqueKeysWithValues: searchIdx.variantDatabaseHandles.map { ($0.trackId, $0.db) }
            )

            var rows: [GenotypeDisplayRow] = []

            let variantsByTrack = Dictionary(grouping: variants, by: \.trackId)
            for (trackId, trackVariants) in variantsByTrack {
                guard let db = handlesByTrack[trackId] else { continue }
                let variantIds = trackVariants.compactMap(\.variantRowId)
                guard !variantIds.isEmpty else { continue }
                let genotypesByVariant = db.genotypes(forVariantIds: variantIds)
                let variantPairs: [(Int64, AnnotationSearchIndex.SearchResult)] = trackVariants.compactMap { variant in
                    guard let rowId = variant.variantRowId else { return nil }
                    return (rowId, variant)
                }
                let variantById = Dictionary(uniqueKeysWithValues: variantPairs)

                for variantId in variantIds {
                    guard let variant = variantById[variantId] else { continue }
                    for gt in genotypesByVariant[variantId] ?? [] {
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
                            alleleBalance: ab
                        ))
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.genotypeFetchGeneration == thisGeneration else { return }
                    self.displayedGenotypes = rows
                    self.tableView.reloadData()
                    self.updateCountLabel()
                }
            }
        }
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

        // Color the GT column based on zygosity
        if identifier == Self.gtGenotypeColumn, row < displayedGenotypes.count {
            let gt = displayedGenotypes[row]
            switch gt.zygosity {
            case "Het":
                cellView.textField?.textColor = .systemOrange
            case "Hom Alt":
                cellView.textField?.textColor = .systemRed
            case "Hom Ref":
                cellView.textField?.textColor = .systemGreen
            default:
                cellView.textField?.textColor = .secondaryLabelColor
            }
        } else if identifier == Self.gtZygosityColumn, row < displayedGenotypes.count {
            let gt = displayedGenotypes[row]
            switch gt.zygosity {
            case "Het":
                cellView.textField?.textColor = .systemOrange
            case "Hom Alt":
                cellView.textField?.textColor = .systemRed
            case "Hom Ref":
                cellView.textField?.textColor = .systemGreen
            default:
                cellView.textField?.textColor = .secondaryLabelColor
            }
        } else {
            cellView.textField?.textColor = .labelColor
        }

        return cellView
    }
}
