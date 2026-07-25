// TwelveSTargetTableView.swift — BatchTableView subclass for 12S target rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Keeps table-column geometry tied to a stable 100% baseline.
///
/// Object identity is part of the baseline key so a metadata column removed
/// and later re-added while content is enlarged starts from its declared
/// width, rather than inheriting the removed column's scaled width.
@MainActor
final class TwelveSAdaptiveColumnWidthState {
    private struct Baseline {
        var objectID: ObjectIdentifier
        var width: CGFloat
        var minimumWidth: CGFloat
        var lastProgrammaticWidth: CGFloat?
        var lastScale: CGFloat
    }

    private var baselines: [String: Baseline] = [:]
    private var isApplying = false

    func captureUserWidths(in tableView: NSTableView) {
        guard !isApplying else { return }
        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            let objectID = ObjectIdentifier(column)
            guard var baseline = baselines[identifier],
                  baseline.objectID == objectID else {
                baselines[identifier] = Baseline(
                    objectID: objectID,
                    width: column.width,
                    minimumWidth: column.minWidth,
                    lastProgrammaticWidth: nil,
                    lastScale: 1
                )
                continue
            }
            if let lastWidth = baseline.lastProgrammaticWidth,
               abs(column.width - lastWidth) > 0.5 {
                baseline.width = column.width / max(baseline.lastScale, 0.01)
            }
            baselines[identifier] = baseline
        }
    }

    func apply(
        to tableView: NSTableView,
        typography: ContentTypography,
        canonicalBodyPointSize: CGFloat
    ) {
        let scale = typography.font(for: .body).pointSize
            / max(canonicalBodyPointSize, 1)
        isApplying = true
        defer { isApplying = false }

        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            let objectID = ObjectIdentifier(column)
            var baseline: Baseline
            if let existing = baselines[identifier], existing.objectID == objectID {
                baseline = existing
            } else {
                baseline = Baseline(
                    objectID: objectID,
                    width: column.width,
                    minimumWidth: column.minWidth,
                    lastProgrammaticWidth: nil,
                    lastScale: 1
                )
            }

            let headerWidth = ceil(column.headerCell.cellSize.width + 20)
            let resolvedMinimum = scale > 1.01
                ? max(baseline.minimumWidth, headerWidth)
                : baseline.minimumWidth
            let resolvedWidth = max(
                resolvedMinimum,
                scale > 1.01
                    ? max(baseline.width * scale, headerWidth)
                    : baseline.width
            )
            column.minWidth = resolvedMinimum
            column.width = resolvedWidth
            baseline.lastProgrammaticWidth = resolvedWidth
            baseline.lastScale = scale
            baselines[identifier] = baseline
        }
    }
}

/// Sortable/filterable table of 12S target rows, projected to one row per
/// sample/species evidence pair.
@MainActor
final class TwelveSTargetTableView: BatchTableView<TwelveSTargetSampleRow> {
    private static let metadataPrefix = "sampleMeta::"
    private let adaptiveColumnWidths = TwelveSAdaptiveColumnWidthState()
    #if DEBUG
    private(set) var typographyApplicationCount = 0
    #endif

    /// Imported sample metadata backing the row-scoped metadata columns (if any).
    private var metadataStore: SampleMetadataStore?
    private var metadataFields: [String] = []

    /// Rebuilds row-scoped sample metadata columns. The reads/percent toggles
    /// are kept in the signature for the existing controller seam, but reads
    /// and percent are now fixed columns on each sample row.
    func setSampleColumns(
        sampleIDs: [String],
        displayNames: [String: String],
        showReads: Bool,
        showPercent: Bool,
        store: SampleMetadataStore?,
        metadataFields: [String]
    ) {
        for column in tableView.tableColumns where Self.metadataField(from: column.identifier.rawValue) != nil
            || TwelveSSampleMatrixColumns.parse(column.identifier.rawValue) != nil {
            tableView.removeTableColumn(column)
        }

        metadataStore = store
        self.metadataFields = metadataFields

        for field in metadataFields {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.metadataColumnID(field)))
            column.title = field
            column.width = 120
            column.minWidth = 70
            column.headerToolTip = field
            column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            tableView.addTableColumn(column)
        }
        applyContentTypography()
    }

    /// Returns the alternate-match display texts for a row (alternate matches,
    /// else potential matches) — used by the Alternates column and detail.
    ///
    /// `nonisolated` because it reads only `Sendable` row data and is needed by
    /// the nonisolated ``TwelveSCopyFormatting`` helpers.
    nonisolated static func alternateTexts(for row: TwelveSTargetSampleRow) -> [String] {
        row.alternateMatches.isEmpty ? row.potentialMatches : row.alternateMatches.map(\.displayName)
    }

    nonisolated static func alternateTexts(for row: TwelveSScientificNameCountRow) -> [String] {
        row.alternateMatches.isEmpty ? row.potentialMatches : row.alternateMatches.map(\.displayName)
    }

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("sampleName"), title: "Sample", width: 170, minWidth: 90, defaultAscending: true),
            .init(identifier: .init("scientificName"), title: "Scientific Name", width: 220, minWidth: 120, defaultAscending: true),
            .init(identifier: .init("commonNames"), title: "Common Names", width: 150, minWidth: 80, defaultAscending: true),
            .init(identifier: .init("taxonGroups"), title: "Group", width: 95, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("taxids"), title: "Tax ID", width: 90, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("totalExactReads"), title: "Exact Reads", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("samplePercent"), title: "% of Sample", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("referenceTargets"), title: "Refs", width: 60, minWidth: 50, defaultAscending: false),
            .init(identifier: .init("alternateMatchCount"), title: "Alternates", width: 85, minWidth: 60, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter species or matches" }
    override var searchAccessibilityIdentifier: String? { "twelve-s-target-search" }
    override var searchAccessibilityLabel: String? { "Filter 12S target match results" }
    override var tableAccessibilityIdentifier: String? { "twelve-s-target-result-table" }
    override var tableAccessibilityLabel: String? { "12S target match results" }

    override func applyContentTypography() {
        guard tableView != nil else { return }
        let scrollOriginY = currentScrollOriginY
        adaptiveColumnWidths.captureUserWidths(in: tableView)
        super.applyContentTypography()
        adaptiveColumnWidths.apply(
            to: tableView,
            typography: resolvedContentTypography(),
            canonicalBodyPointSize: canonicalContentPointSize(for: .body)
        )
        restoreScrollOriginY(scrollOriginY)
        #if DEBUG
        typographyApplicationCount += 1
        #endif
    }

    override var columnTypeHints: [String: Bool] {
        [
            "totalExactReads": true,
            "samplePercent": true,
            "referenceTargets": true,
            "alternateMatchCount": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TwelveSTargetSampleRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "sampleName":          return (row.sampleDisplayName, .left, nil)
        case "scientificName":      return (row.scientificName, .left, nil)
        case "commonNames":         return (row.commonNamesText, .left, nil)
        case "taxonGroups":         return (row.displayTaxonGroups.joined(separator: "; "), .left, nil)
        case "taxids":              return (row.taxids.joined(separator: "; "), .left, nil)
        case "totalExactReads":     return (String(row.exactReads), .right, nil)
        case "samplePercent":       return (String(format: "%.1f%%", row.samplePercent), .right, nil)
        case "referenceTargets":    return (String(row.referenceTargetCount), .right, nil)
        case "alternateMatchCount": return (String(Self.alternateTexts(for: row).count), .right, nil)
        default:
            guard let field = Self.metadataField(from: column.rawValue) else {
                return ("", .left, nil)
            }
            return (metadataStore?.records[row.sampleID]?[field] ?? "", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: TwelveSTargetSampleRow) -> String {
        switch columnId {
        case "sampleName":          return row.sampleDisplayName
        case "totalExactReads":     return String(row.exactReads)
        case "samplePercent":       return String(row.samplePercent)
        case "referenceTargets":    return String(row.referenceTargetCount)
        case "alternateMatchCount": return String(Self.alternateTexts(for: row).count)
        default:                    return cellContent(for: .init(columnId), row: row).text
        }
    }

    override func compareRows(
        _ lhs: TwelveSTargetSampleRow,
        _ rhs: TwelveSTargetSampleRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "totalExactReads":
            return ascending ? lhs.exactReads < rhs.exactReads : lhs.exactReads > rhs.exactReads
        case "samplePercent":
            return ascending ? lhs.samplePercent < rhs.samplePercent : lhs.samplePercent > rhs.samplePercent
        case "referenceTargets":
            return ascending ? lhs.referenceTargetCount < rhs.referenceTargetCount : lhs.referenceTargetCount > rhs.referenceTargetCount
        case "alternateMatchCount":
            let l = Self.alternateTexts(for: lhs).count, r = Self.alternateTexts(for: rhs).count
            return ascending ? l < r : l > r
        default:
            let l = cellContent(for: .init(key), row: lhs).text
            let r = cellContent(for: .init(key), row: rhs).text
            let cmp = l.localizedStandardCompare(r)
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    override func rowMatchesFilter(_ row: TwelveSTargetSampleRow, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let metadata = metadataFields.compactMap { metadataStore?.records[row.sampleID]?[$0] }
        let haystack = ([
            row.sampleDisplayName,
            row.sampleID,
            row.scientificName,
            row.commonNamesText,
            row.potentialMatchesText,
            row.displayTaxonGroups.joined(separator: " "),
            row.taxids.joined(separator: " "),
            row.targetIDs.joined(separator: " "),
        ] + metadata).joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    override func rowIdentity(for row: TwelveSTargetSampleRow) -> String? {
        let prefix = resultIdentity ?? ""
        return "\(prefix)|\(row.sampleID)|\(row.scientificName)|\(row.taxids.joined(separator: ","))"
    }

    private static func metadataColumnID(_ field: String) -> String {
        metadataPrefix + field
    }

    private static func metadataField(from id: String) -> String? {
        guard id.hasPrefix(metadataPrefix) else { return nil }
        return String(id.dropFirst(metadataPrefix.count))
    }
}
