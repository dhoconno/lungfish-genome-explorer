// MSAPairwiseDistanceSection.swift - Inspector pointer to the distance matrix plus the focused pair breakdown
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishIO
import LungfishAlignmentUI

/// State for the Inspector's Pairwise Distance section (ruling U3). The
/// matrix itself lives in the Distances tab under the alignment. This model
/// keeps the expanded state, so it survives the Inspector's tab switches,
/// and the breakdown of the matrix cell that has keyboard focus.
@MainActor
@Observable
final class MSAPairwiseDistanceInspectorModel {
    let bundleURL: URL
    var isExpanded = false
    var focusedPair: MSAFocusedDistancePair?
    /// Same action as View > Show Distance Matrix.
    @ObservationIgnored var onShowDistanceMatrix: (() -> Void)?

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    func showDistanceMatrix() {
        if let onShowDistanceMatrix {
            onShowDistanceMatrix()
        } else {
            NSApp.sendAction(#selector(DistanceMatrixMenuActions.showDistanceMatrix(_:)), to: nil, from: nil)
        }
    }

    /// Label and value rows for the focused pair, in reading order.
    var breakdownRows: [(label: String, value: String)] {
        guard let pair = focusedPair else { return [] }
        let detail = pair.detail
        let count = MSADistanceValueFormat.count
        var rows: [(label: String, value: String)] = [
            ("Pair", "\(pair.rowName) vs \(pair.columnName)"),
            ("Model", pair.model.displayName),
            ("Value", Self.valueText(detail: detail, model: pair.model)),
            ("Compared Sites", count(detail.comparableSites)),
            ("Differences", count(detail.differences)),
            ("Identical Sites", count(detail.identicalSites)),
            ("Gap-skipped", count(detail.gapSkipped)),
            ("Ambiguity-skipped", count(detail.ambiguitySkipped)),
        ]
        if pair.model == .k2p {
            rows.append(("Transitions", count(detail.transitions)))
            rows.append(("Transversions", count(detail.transversions)))
        }
        return rows
    }

    static func valueText(detail: MSAPairDetail, model: MSADistanceModel) -> String {
        if detail.isUndefined {
            return "Not defined. The two sequences share no comparable sites."
        }
        if detail.isSaturated {
            return "Saturated. The sequences differ at too many sites for the \(model.displayName) correction, so the distance cannot be estimated."
        }
        return MSADistanceValueFormat.full(detail.value)
    }
}

struct MSAPairwiseDistanceSection: View {
    @Bindable var model: MSAPairwiseDistanceInspectorModel

    var body: some View {
        DisclosureGroup("Pairwise Distance", isExpanded: $model.isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Show Distance Matrix") { model.showDistanceMatrix() }
                    .font(LungfishInspectorStyle.controlFont)
                    .help("Open the Distances tab under the alignment (Control-Command-M)")
                    .accessibilityIdentifier("msa-pairwise-distance-show-matrix")
                if model.focusedPair == nil {
                    Text("Focus a cell in the distance matrix to see how its value was computed.")
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A grid sizes the label column to its widest label, so it
                    // grows with the text size instead of a fixed width (review N9).
                    Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(Array(model.breakdownRows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label)
                                    .font(LungfishInspectorStyle.controlFont)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.value)
                                    .font(LungfishInspectorStyle.controlFont)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
        .accessibilityIdentifier("msa-pairwise-distance-section")
    }
}
