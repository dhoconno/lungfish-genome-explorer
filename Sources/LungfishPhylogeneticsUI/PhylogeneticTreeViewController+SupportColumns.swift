// PhylogeneticTreeViewController+SupportColumns.swift - per-label support columns and the support legend (V1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

extension PhylogeneticTreeViewController {
    /// The support labels the displayed bundle recorded, empty for older imports.
    var recordedSupportLabels: [String] {
        bundle?.manifest.supportLabels ?? []
    }

    /// Places the legend on the summary line, at the trailing edge.
    func installSupportLegend() {
        supportLegendLabel.lineBreakMode = .byTruncatingTail
        supportLegendLabel.maximumNumberOfLines = 1
        supportLegendLabel.isSelectable = true
        supportLegendLabel.isHidden = true
        supportLegendLabel.setAccessibilityLabel("Support color legend")
        supportLegendLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        supportLegendLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.addSubview(supportLegendLabel)
        NSLayoutConstraint.activate([
            supportLegendLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 16
            ),
            supportLegendLabel.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -12),
            supportLegendLabel.firstBaselineAnchor.constraint(equalTo: summaryLabel.firstBaselineAnchor),
        ])
    }

    /// Rebuilds the support columns for the displayed bundle's labels and refreshes the legend.
    func configureSupportPresentation() {
        let wanted = PhylogeneticTreeSupportPresentation.columns(labels: recordedSupportLabels)
        let current = nodeTableView.tableColumns.filter {
            PhylogeneticTreeSupportPresentation.isSupportColumnID($0.identifier.rawValue)
        }
        if current.map({ $0.identifier.rawValue }) != wanted.map(\.id) {
            current.forEach { nodeTableView.removeTableColumn($0) }
            wanted.forEach { addTableColumn(id: $0.id, title: $0.title, width: 72) }
            applyContentTypography()
        }
        refreshSupportLegend()
    }

    /// Shows the legend while the canvas is coloured by support and the bundle recorded labels.
    func refreshSupportLegend() {
        let labels = recordedSupportLabels
        let isVisible = colorModeControl.selectedSegment == 1 && !labels.isEmpty
        supportLegendLabel.isHidden = !isVisible
        guard isVisible else {
            supportLegendLabel.stringValue = ""
            return
        }
        let font = supportLegendLabel.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        supportLegendLabel.attributedStringValue = PhylogeneticTreeSupportPresentation.legendAttributedString(
            labels: labels,
            font: font
        )
        let accessibilityValue = PhylogeneticTreeSupportPresentation.legendAccessibilityValue(labels: labels)
        supportLegendLabel.setAccessibilityValue(accessibilityValue)
        supportLegendLabel.toolTip = accessibilityValue
    }
}

#if DEBUG
extension PhylogeneticTreeViewController {
    var testingSummaryText: String { summaryLabel.stringValue }

    var testingSupportLegendIsHidden: Bool { supportLegendLabel.isHidden }

    var testingSupportLegendText: String? {
        PhylogeneticTreeSupportPresentation.legendText(labels: recordedSupportLabels)
    }

    func testingRowIndex(ofSupportText text: String) -> Int? {
        let supportColumns = testingNodeTableView.tableColumns.filter {
            PhylogeneticTreeSupportPresentation.isSupportColumnID($0.identifier.rawValue)
        }
        for row in 0..<testingNodeTableView.numberOfRows {
            let values = supportColumns.map {
                testingNodeCellAccessibilityValue(column: $0.identifier.rawValue, row: row)
            }
            if values.joined(separator: "/") == text { return row }
        }
        return nil
    }
}
#endif
